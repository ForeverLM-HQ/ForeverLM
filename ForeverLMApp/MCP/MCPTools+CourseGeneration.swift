import Foundation

extension MCPDataStore {

    /// `generate_course`: the same pipeline the Mac's Generate sheet runs, driven
    /// from an assistant. Web pages the research cites are imported through the
    /// store's own paper and source imports, so the course points at library
    /// sources exactly as the in-app path does.
    ///
    /// The minutes of research and lesson writing hold no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the writer reads and saves
    /// through the storage actor, and only each cited page's import, which
    /// writes the cached connection, holds the gate alone.
    func generateCourse(
        topic: String,
        learnerNotes: String?,
        useWeb: Bool,
        moduleCount: Int?,
        scheduleStart: String?,
        daysPerModule: Int?,
        writeQuizzes: Bool = false,
        chosenSourceIDs: [String] = [],
        agreedPlan: String? = nil,
        notebookID: String? = nil
    ) async throws -> String {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else {
            throw MCPError.invalidInput("topic is required.")
        }
        if let moduleCount, !CourseGenerationRequest.moduleCountRange.contains(moduleCount) {
            throw MCPError.invalidInput(
                "module_count must be between \(CourseGenerationRequest.moduleCountRange.lowerBound) and \(CourseGenerationRequest.moduleCountRange.upperBound)."
            )
        }
        if let daysPerModule, !CourseGenerationRequest.daysPerModuleRange.contains(daysPerModule) {
            throw MCPError.invalidInput(
                "days_per_module must be between \(CourseGenerationRequest.daysPerModuleRange.lowerBound) and \(CourseGenerationRequest.daysPerModuleRange.upperBound)."
            )
        }
        let start = try scheduleStart
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { try parseSourceSearchDate($0, field: "schedule_start", calendar: Calendar.current) }
        // The notebook that follows the course, checked before anything is
        // paid for. A generated course is the learner's own, so only a
        // notebook of My Library follows it.
        let notebook = try await notebookForMadeThing(notebookID: notebookID)
        if let notebook, notebook.teamID != nil {
            throw MCPError.invalidInput(
                "‘\(notebook.title)’ is a team's Notebook. A generated course is made in My Library, so only a Notebook of My Library follows it: pass one from list_notebooks, or leave notebook_id out. share_with_team copies the course into the team afterwards."
            )
        }

        let request = CourseGenerationRequest(
            topic: trimmedTopic,
            learnerNotes: learnerNotes ?? "",
            learnerBackground: LearnerProfile.aboutYou,
            usesWeb: useWeb,
            moduleCount: moduleCount,
            scheduleStart: start,
            daysPerModule: daysPerModule ?? 2,
            chosenSourceIDs: chosenSourceIDs,
            agreedPlan: agreedPlan ?? "",
            followingNotebookID: notebook?.id
        )

        let service = CourseGeneratorService(
            storage: notebookFileStorage,
            backend: LiveCourseGenerationModelBackend(aiService: AIService()),
            importWebSource: { [self] candidate in
                try await self.importCourseWebCandidate(candidate)
            }
        )
        let result: CourseGenerationResult
        let activity = MCPToolActivityReporter.current
        do {
            result = try await service.run(request: request) { progress in
                activity?.reportNow(progress.stage.label)
            }
        } catch let error as CourseGenerationError {
            throw MCPError.invalidInput(error.localizedDescription)
        }

        var lines: [String] = []
        // The new course's id rides on its own line, and each module's
        // sources are the links a reply shows (Prompts.hiddenIDs).
        lines.append("Generated course '\(result.blueprint.title)' with \(result.lectures.count) modules.")
        lines.append("course_id: \(result.courseID)")
        let readTitles = try sourceMetadataByID(result.blueprint.modules.flatMap(\.sourceIDs))
        if !result.blueprint.summary.isEmpty {
            lines.append(result.blueprint.summary)
        }
        for (index, lecture) in result.lectures.enumerated() {
            let module = result.blueprint.modules[index]
            var line = "\(lecture.number). \(module.title) (lecture_id: \(lecture.id)"
            if index < result.lessonSourceIDs.count {
                line += ", lesson_source_id: \(result.lessonSourceIDs[index])"
            }
            if index < result.exerciseSourceIDs.count {
                line += ", exercises_source_id: \(result.exerciseSourceIDs[index])"
            }
            line += ")"
            if !module.sourceIDs.isEmpty {
                line += " reads: " + module.sourceIDs.map { id in
                    (readTitles[id]?["title"] as? String).map { Self.sourceLink(title: $0, id: id) } ?? id
                }.joined(separator: ", ")
            }
            lines.append(line)
        }
        // Which Notebook follows the course (docs/courses-design.md): the
        // course itself lives in none.
        let followerTitle: String?
        if let followerID = result.notebookID {
            followerTitle = (try? await notebookFileStorage.loadLearningGoal(followerID))?.title ?? result.blueprint.title
        } else {
            followerTitle = nil
        }
        if let followerID = result.notebookID, let followerTitle {
            let made = result.madeNotebookForCourse ? ", made for it" : ""
            lines.append("notebook_id_applied: \(followerID) — Notebook '\(followerTitle)'\(made) follows the course: it holds its sources and gains the lectures the course gains. The course itself lives in no Notebook.")
        } else if let notebook {
            lines.append("notebook_id_applied: none — Notebook '\(notebook.title)' could no longer follow the course, so no Notebook does; update_course with notebook_id makes one follow it.")
        } else {
            lines.append("notebook_id_applied: none — no Notebook follows the course (it lives in no Notebook); update_course with notebook_id makes one follow it.")
        }
        if let goalID = result.goalID {
            let goal = try? await notebookFileStorage.loadLearningGoal(goalID)
            let due = goal.map { " due \(isoDateOnly($0.endAt))" } ?? ""
            let goalTitle = goal?.title ?? CourseGeneratorService.scheduleGoalTitle(courseTitle: result.blueprint.title)
            lines.append("Scheduled: Goal '\(goalTitle)', in that Notebook\(due), places one module every \(request.daysPerModule) day(s). Call get_goal with goal_id \(goalID) for the Goal, or get_schedule with it to see the days.")
        }
        if writeQuizzes {
            // The same ladder generate_course_quizzes writes, over the lessons
            // just written (docs/lecture-quiz-design.md).
            await MCPToolActivityReporter.current?.retitle("Writing quizzes for \(result.blueprint.title)")
            let quizzes = try await generateCourseQuizzes(arguments: ["course_id": result.courseID])
            lines.append("")
            lines.append(quizzes)
        }
        lines.append("Open a lesson with get_source_content, or review one with start_review_session using its source id.")
        return lines.joined(separator: "\n")
    }

    /// Imports one cited page and returns the library source id it became, or
    /// nil when the page produced no source. Papers go through the paper import
    /// so the mandatory metadata gate runs; anything else is added as an article
    /// whose text the app fetches in the background. Holds the store gate alone
    /// for the import, models included: the course wants each paper read
    /// before it is planned around.
    func importCourseWebCandidate(_ candidate: DeepResearchCandidate) async throws -> String? {
        try await withStoreGate(.exclusive) {
            try await importCourseWebCandidateHoldingGate(candidate)
        }
    }

    private func importCourseWebCandidateHoldingGate(_ candidate: DeepResearchCandidate) async throws -> String? {
        let store = try knowledgeStore()
        let normalized = URLNormalizer.normalize(candidate.url)
        if let existing = store.sourceExistsByNormalizedURL(normalized) {
            return existing.status == .active ? existing.id : nil
        }
        if StudioViewModel.detectSourceType(url: candidate.url) == .paper {
            _ = try await importPaperFromURL(candidate.url, title: candidate.title)
        } else {
            _ = try addSource(
                url: candidate.url,
                title: candidate.title,
                sourceType: StudioSourceType.article.rawValue,
                content: nil,
                parentGroup: nil,
                author: nil
            )
        }
        guard let created = store.sourceExistsByNormalizedURL(normalized) ?? store.sourceExistsByURL(candidate.url),
              created.status == .active else {
            return nil
        }
        return created.id
    }
}
