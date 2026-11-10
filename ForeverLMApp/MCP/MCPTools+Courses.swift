import Foundation

extension MCPDataStore {

    // MARK: - Course discovery and identity

    struct CoursePaperAssociation {
        let lecture: CourseSession
        let source: StudioArticle
        let item: CourseLectureItem
        let created: Bool
        /// An existing association whose role this call changed.
        var roleChanged = false
    }

    /// Course titles are user-authored display text, not identity. Resolve an exact
    /// stable ID first, then allow a normalized display-title match only when it is
    /// unique. Ambiguity must fail loudly so an MCP client cannot silently create or
    /// populate a second course with the same visible title.
    func resolveExistingCourseID(
        input: String,
        store: KnowledgeStore,
        preferStableID: Bool = true
    ) throws -> String {
        let identifier = try Self.requiredCourseIdentifier(input)
        return try Self.resolveExistingCourseID(
            identifier: identifier,
            groups: try store.loadCourseGroups(),
            lectureCourseIDs: Set(try store.loadCourseLectures().map(\.courseName)),
            preferStableID: preferStableID
        )
    }

    /// The same resolution read through the storage actor, for a tool that
    /// holds no store gate while it runs.
    func resolveExistingCourseID(
        input: String,
        storage: StorageService,
        preferStableID: Bool = true
    ) async throws -> String {
        let identifier = try Self.requiredCourseIdentifier(input)
        return try Self.resolveExistingCourseID(
            identifier: identifier,
            groups: try await storage.loadCourseMetadata(),
            lectureCourseIDs: Set(try await storage.loadCourseLectures().map(\.courseName)),
            preferStableID: preferStableID
        )
    }

    private static func requiredCourseIdentifier(_ input: String) throws -> String {
        let identifier = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw MCPError.invalidInput("course_id or course_name is required. Call list_courses first.")
        }
        return identifier
    }

    private static func resolveExistingCourseID(
        identifier: String,
        groups: [String: CourseMetadata],
        lectureCourseIDs: Set<String>,
        preferStableID: Bool
    ) throws -> String {
        if preferStableID, groups[identifier] != nil || lectureCourseIDs.contains(identifier) {
            return identifier
        }

        let normalizedInput = Self.normalizedCourseLookupValue(identifier)
        let knownCourseIDs = Set(groups.keys).union(lectureCourseIDs)
        let matches = knownCourseIDs
            .compactMap { courseID -> (key: String, value: CourseMetadata)? in
                let metadata = groups[courseID] ?? CourseMetadata(title: courseID)
                let title = metadata.title ?? courseID
                guard Self.normalizedCourseLookupValue(title) == normalizedInput else { return nil }
                return (key: courseID, value: metadata)
            }
            .sorted { $0.key < $1.key }

        if matches.count == 1, let match = matches.first {
            return match.key
        }
        if matches.count > 1 {
            let candidates = matches.map { match in
                Self.courseCandidateLabel(courseID: match.key, metadata: match.value)
            }.joined(separator: "; ")
            throw MCPError.invalidInput(
                "Multiple courses match '\(identifier)': \(candidates). Call list_courses and pass the intended stable course_id."
            )
        }

        throw MCPError.notFound(
            "Course not found: \(identifier). Call list_courses first; call create_course only when no matching course exists."
        )
    }

    /// Resolve a course group for source ingest/update. Unlike the old SQL `LIMIT
    /// 1` path, duplicate display titles are never chosen nondeterministically.
    /// Existing stable IDs win; a unique title resolves to that ID; only a genuine
    /// miss creates a course, under a fresh UUID with the input as its title —
    /// the identity `create_course` and the app's playlist import give a course.
    /// Until 2026-09-26 a miss keyed the new course by its display title, so a
    /// course first named through add_source kept its title as its ID for good:
    /// "Mitochondrial Bioenergetics Graduate Course" was one, and renaming it
    /// would have left the old title standing as its identity.
    func resolveOrCreateCourseID(input: String, store: KnowledgeStore) throws -> String {
        let identifier = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return identifier }

        do {
            return try resolveExistingCourseID(input: identifier, store: store)
        } catch let error as MCPError {
            switch error {
            case .notFound:
                let courseID = UUID().uuidString
                try store.saveCourseGroup(
                    name: courseID,
                    metadata: CourseMetadata(title: identifier)
                )
                return courseID
            default:
                throw error
            }
        }
    }

    /// Destructive or metadata-changing course operations accept only an exact,
    /// stable course ID. Display-title fallback is intentionally unavailable at
    /// this boundary, even when the title is currently unique.
    func requireExistingStableCourseID(input: String, store: KnowledgeStore) throws -> String {
        let courseID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !courseID.isEmpty else {
            throw MCPError.invalidInput("course_id is required. Call list_courses first.")
        }

        let groups = try store.loadCourseGroups()
        let lectures = try store.loadCourseLectures()
        let sources = try store.loadActiveSources()
        let knownCourseIDs = Set(groups.keys)
            .union(lectures.map(\.courseName))
            .union(
                sources
                    .filter { $0.sourceType == .course }
                    .compactMap(\.parentGroup)
            )

        guard knownCourseIDs.contains(courseID) else {
            let normalizedInput = Self.normalizedCourseLookupValue(courseID)
            let titleMatches = knownCourseIDs
                .filter { candidateID in
                    let title = groups[candidateID]?.title ?? candidateID
                    return Self.normalizedCourseLookupValue(title) == normalizedInput
                }
                .sorted()
            if !titleMatches.isEmpty {
                let candidates = titleMatches.map { candidateID in
                    Self.courseCandidateLabel(
                        courseID: candidateID,
                        metadata: groups[candidateID] ?? CourseMetadata(title: candidateID)
                    )
                }.joined(separator: "; ")
                throw MCPError.invalidInput(
                    "This operation requires the stable course_id, not a display title. Matching courses: \(candidates)"
                )
            }
            throw MCPError.notFound("Course not found: \(courseID). Call list_courses first.")
        }
        return courseID
    }

    func listCourses(notebookID: String? = nil) throws -> String {
        let store = try knowledgeStore()
        // notebook_id: only the courses that Notebook follows
        // (`NotebookMembership`, a course's links). A course lives in no
        // Notebook; following is the one tie.
        let notebook = try notebookMembershipForListing(notebookID: notebookID, store: store)
        let followers = try store.loadCourseFollowers()
        let groups = try store.loadCourseGroups()
        let lectures = try store.loadCourseLectures()
        let lectureItems = try store.loadCourseLectureItems()
        // Screen record mode (admin only): a course shows only when it is
        // followed by the recording Notebook, or through a lesson the take may
        // show (`ScreenRecordScope.allowsCourse`, which the app's Courses tab
        // asks too). Nil scope, the non-admin case, changes nothing.
        let screenScope = screenRecordScope()
        let screenRecordHidden = try screenRecordHiddenSourceIDs(scope: screenScope)
        let sources = try store.loadActiveSources().filter { !screenRecordHidden.contains($0.id) }

        var courseIDs = Set(groups.keys)
        courseIDs.formUnion(lectures.map(\.courseName))
        let groupedCourseIDs = Set(
            sources
                .filter { $0.sourceType == .course }
                .compactMap(\.parentGroup)
        )
        courseIDs.formUnion(groupedCourseIDs)
        if let screenScope {
            let shownLessons = try store.screenRecordCoursesWithShownLesson(scope: screenScope)
            courseIDs = courseIDs.filter {
                screenScope.allowsCourse(
                    followedBy: followers[$0] ?? [], hasShownLesson: shownLessons.contains($0)
                )
            }
        }
        if let notebook {
            courseIDs = courseIDs.filter { notebook.containsCourse(followedBy: followers[$0] ?? []) }
        }

        guard !courseIDs.isEmpty else {
            if let notebook {
                return "Courses in Notebook \(notebook.notebookID) (0):\nThis Notebook follows no course. update_course with notebook_id makes it follow one."
            }
            return "Courses (0):\nNo courses found."
        }

        let lecturesByCourse = Dictionary(grouping: lectures, by: \.courseName)
        let itemsByLecture = Dictionary(grouping: lectureItems, by: \.lectureId)
        let sourcesByCourse = Dictionary(grouping: sources.compactMap { source -> (String, StudioArticle)? in
            guard source.sourceType == .course, let courseID = source.parentGroup else { return nil }
            return (courseID, source)
        }, by: { $0.0 })

        let sortedCourseIDs = courseIDs.sorted { lhs, rhs in
            let lhsTitle = groups[lhs]?.title ?? lhs
            let rhsTitle = groups[rhs]?.title ?? rhs
            let comparison = lhsTitle.localizedStandardCompare(rhsTitle)
            return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
        }

        // A team's course (docs/teams-design.md, decision 21) says whose.
        let teamIDs = try store.loadCourseTeamIDs()
        var lines = [notebook.map { "Courses in Notebook \($0.notebookID) (\(sortedCourseIDs.count)):" } ?? "Courses (\(sortedCourseIDs.count)):"]
        for courseID in sortedCourseIDs {
            let metadata = groups[courseID]
            let title = metadata?.title ?? courseID
            let courseLectures = lecturesByCourse[courseID] ?? []
            let lectureItemCount = courseLectures.reduce(0) {
                $0 + (itemsByLecture[$1.id]?.count ?? 0)
            }
            let groupedSourceCount = sourcesByCourse[courseID]?.count ?? 0
            var details = [
                "id: \(courseID)",
                "lectures: \(courseLectures.count)",
                "grouped_sources: \(groupedSourceCount)",
                "lecture_items: \(lectureItemCount)",
            ]
            if let courseCode = Self.nilIfBlank(metadata?.courseCode ?? "") {
                details.append("course_code: \(courseCode)")
            }
            if let institution = Self.nilIfBlank(metadata?.institution ?? "") {
                details.append("institution: \(institution)")
            }
            if let instructors = Self.nilIfBlank(metadata?.instructors ?? "") {
                details.append("instructors: \(instructors)")
            }
            if metadata?.isHidden == true {
                details.append("hidden: true")
            }
            if let teamID = teamIDs[courseID] {
                details.append("team_id: \(teamID)")
            }
            // The Notebooks that follow it; a course lives in none, so none of
            // them is where it lives.
            if let following = followers[courseID], !following.isEmpty {
                details.append("followed_by_notebook_ids: \(following.joined(separator: ","))")
            }
            if metadata == nil {
                details.append("metadata: missing")
            }
            lines.append("- \(title) (\(details.joined(separator: ", ")))")
        }
        lines.append("Use the stable id with get_course and all course write tools. A course lives in no Notebook; followed_by_notebook_ids lists the Notebooks that follow it, and update_course with notebook_id makes another follow it.")
        return lines.joined(separator: "\n")
    }

    func getCourse(courseIdentifier: String) throws -> String {
        let store = try knowledgeStore()
        let courseID = try resolveExistingCourseID(input: courseIdentifier, store: store)
        let metadata = try store.loadCourseGroups()[courseID]
        let lectures = try store.loadCourseLectures()
            .filter { $0.courseName == courseID }
            .sorted { lhs, rhs in
                lhs.number == rhs.number ? lhs.id < rhs.id : lhs.number < rhs.number
            }
        let lectureIDs = Set(lectures.map(\.id))
        let items = try store.loadCourseLectureItems()
            .filter { lectureIDs.contains($0.lectureId) }
        let itemsByLecture = Dictionary(grouping: items, by: \.lectureId)
        let sources = try store.loadActiveSources()
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let groupedSources = sources
            .filter { $0.sourceType == .course && $0.parentGroup == courseID }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let attachedSourceIDs = Set(items.compactMap(\.sourceId))
        let unassignedSources = groupedSources.filter { !attachedSourceIDs.contains($0.id) }
        // The course's stored quizzes, placed after the lecture each follows.
        let quizzes = try store.loadCourseQuizzes(courseID: courseID)
        let placements = CourseQuizPlanning.placements(quizzes: quizzes, lectureOrder: lectures.map(\.id))
        let storedQuizScores = LectureQuizScore.scoresFromDefaults(prefix: LectureQuizScore.courseQuizPreferenceKeyPrefix)
        // Each quiz's sitting under way, answered in the app or recorded by
        // an assistant (`record_course_quiz_result`).
        let sittings = CourseQuizSitting.latest(rows: try store.loadCourseQuizSittingRows(), quizzes: quizzes)
        // The pages a textbook reading names (docs/textbook-readings-design.md).
        let sourceUnits = try store.loadCourseSourceUnits()
        let lectureNumbers = Dictionary(lectures.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        // A quiz's latest sitting, as the app reads it.
        func score(of quiz: CourseQuiz) -> LectureQuizScore? {
            storedQuizScores[quiz.id]
        }
        // The course's gate (docs/courses-design.md): the first written quiz on
        // the path without a finished sitting holds back what comes after it.
        let pathQuizzes = lectures.flatMap { placements.afterLecture[$0.id] ?? [] } + placements.atEnd
        let blockingQuiz = pathQuizzes.first { !$0.questions.isEmpty && score(of: $0) == nil }
        func quizLine(_ quiz: CourseQuiz) -> String {
            let numbers = quiz.lectureIDs.compactMap { lectureNumbers[$0] }.sorted()
            var details = [
                "quiz_id: \(quiz.id)",
                "kind: \(quiz.kind.rawValue)",
                "\(quiz.questions.count) questions",
            ]
            if quiz.kind != .practice, let first = numbers.first, let last = numbers.last {
                details.append(first == last ? "covers lecture \(first)" : "covers lectures \(first)–\(last)")
            }
            if quiz.author == .assistant { details.append("written by an assistant") }
            let latest = score(of: quiz)
            let currentScore = latest.flatMap { $0.matches(questionCount: quiz.questions.count) ? $0 : nil }
            if let latest, currentScore == nil {
                details.append("score: previous version \(latest.label)")
                details.append("previous version completed")
                if latest.hasPassed { details.append("previous version passed") }
            } else {
                details.append("score: \(currentScore?.label ?? "not taken")")
            }
            if let latest = currentScore {
                details.append("completed")
                if latest.hasPassed { details.append("passed") }
                else if !quiz.questions.isEmpty {
                    let needed = LectureQuizScore.rightNeededToPass(total: latest.total)
                    details.append("not passed (\(needed) right to pass; completion still opens the course)")
                }
            } else if latest == nil, !quiz.questions.isEmpty {
                let needed = LectureQuizScore.rightNeededToPass(total: quiz.questions.count)
                details.append("not passed (\(needed) right to pass)")
            }
            if let open = sittings[quiz.id], open.isUnderWay {
                details.append("sitting under way: \(open.done) of \(open.total) answered")
            }
            // The link opens the quiz in its own chat in the app, so a chat
            // or assistant hands the learner the written quiz rather than
            // improvising one.
            details.append("link: \(StudioEntityLink.quiz(quiz.id).markdownDestination)")
            return "  ▸ \(quiz.title) (\(details.joined(separator: ", ")))"
        }

        let title = metadata?.title ?? courseID
        var lines = [
            "Course: \(title)",
            "course_id: \(courseID)",
        ]
        if let teamID = try store.courseTeamID(courseID) {
            lines.append("team_id: \(teamID) (a team's copy; each member's progress is their own)")
        }
        // A course lives in no Notebook (docs/courses-design.md); a Notebook
        // may follow it, so its sources — and every source the course gains —
        // join that Notebook.
        let followers = try store.notebookIDsFollowingCourse(courseID)
        if followers.isEmpty {
            lines.append("followed_by: none (a course lives in no Notebook; update_course with notebook_id makes a Notebook follow it)")
        } else {
            let named = try followers.map { id -> String in
                let title = try store.loadLearningGoal(id)?.title ?? id
                return "\(id) (‘\(title)’)"
            }
            lines.append("followed_by: \(named.joined(separator: ", ")) (Notebooks whose sources follow the course)")
        }
        if let courseCode = Self.nilIfBlank(metadata?.courseCode ?? "") {
            lines.append("course_code: \(courseCode)")
        }
        if let institution = Self.nilIfBlank(metadata?.institution ?? "") {
            lines.append("institution: \(institution)")
        }
        if let instructors = Self.nilIfBlank(metadata?.instructors ?? "") {
            lines.append("instructors: \(instructors)")
        }
        if let playlistURL = Self.nilIfBlank(metadata?.playlistURL ?? "") {
            lines.append("playlist_url: \(playlistURL)")
        }
        lines.append("hidden: \(metadata?.isHidden == true ? "true" : "false")")
        let focus = LearnerProfile.courseFocus(courseID: courseID)
        if !focus.isEmpty {
            lines.append("learner_focus: \(focus)")
        }
        lines.append("lectures: \(lectures.count), grouped_sources: \(groupedSources.count), lecture_items: \(items.count)")
        let kinds = Dictionary(grouping: quizzes, by: \.kind).mapValues(\.count)
        lines.append("quizzes: \(quizzes.count) (practice \(kinds[.practice] ?? 0), checkpoint \(kinds[.checkpoint] ?? 0), test \(kinds[.test] ?? 0))\(quizzes.isEmpty ? "; call generate_course_quizzes to write them" : "")")
        if let blockingQuiz {
            lines.append("gate: \(blockingQuiz.title) (quiz_id: \(blockingQuiz.id)) is the next quiz to complete; in the app, what comes after it stays locked until the sitting is finished (the score remains visible, and what the learner already finished stays open)")
        } else if !pathQuizzes.isEmpty {
            lines.append("gate: every quiz is completed; nothing is locked")
        }

        lines.append("")
        lines.append("Lectures:")
        if lectures.isEmpty {
            lines.append("- None")
        } else {
            var lockedBehind: CourseQuiz?
            for lecture in lectures {
                let lectureTitle = Self.nilIfBlank(lecture.title ?? "") ?? "Lecture \(lecture.number)"
                let lock = lockedBehind.map { ", locked until quiz_id \($0.id) is completed" } ?? ""
                lines.append("- \(lecture.number). \(lectureTitle) (lecture_id: \(lecture.id)\(lock))")
                let lectureItems = (itemsByLecture[lecture.id] ?? []).sorted {
                    $0.sortIndex == $1.sortIndex ? $0.id < $1.id : $0.sortIndex < $1.sortIndex
                }
                for item in lectureItems {
                    if item.role == .reading,
                       let chapter = item.sourceId.flatMap({ sourcesByID[$0] }),
                       chapter.sourceType == .book {
                        lines.append(Self.textbookReadingLine(item: item, chapter: chapter, unit: item.sourceUnitId.flatMap { sourceUnits[$0] }))
                        continue
                    }
                    let sourceTitle = item.sourceId.flatMap { sourcesByID[$0]?.title }
                        ?? item.label
                        ?? "Unavailable source"
                    var details = [
                        "item_id: \(item.id)",
                        "role: \(item.role.rawValue)",
                    ]
                    if let sourceID = item.sourceId {
                        details.append("source_id: \(sourceID)")
                    }
                    if let sourceUnitID = item.sourceUnitId {
                        details.append("source_unit_id: \(sourceUnitID)")
                    }
                    lines.append("  - \(sourceTitle) (\(details.joined(separator: ", ")))")
                }
                for quiz in placements.afterLecture[lecture.id] ?? [] {
                    lines.append(quizLine(quiz))
                    if lockedBehind == nil, quiz.id == blockingQuiz?.id {
                        lockedBehind = quiz
                    }
                }
            }
        }
        if !placements.atEnd.isEmpty {
            lines.append("- End of course")
            for quiz in placements.atEnd {
                lines.append(quizLine(quiz))
            }
        }

        lines.append("")
        lines.append("Unassigned course sources:")
        if unassignedSources.isEmpty {
            lines.append("- None")
        } else {
            for source in unassignedSources {
                lines.append("- \(source.title) (source_id: \(source.id), type: \(source.sourceType.rawValue))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Return the canonical paper sources attached to one lecture. Paper identity
    /// comes from the source record, not the lecture-item role: older builds stored
    /// papers as `reading`, and callers may also have used `reference` or `other`.
    func getLecturePapers(lectureID input: String) throws -> String {
        let store = try knowledgeStore()
        let lectureID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lectureID.isEmpty else {
            throw MCPError.invalidInput("lecture_id is required. Call get_course to see lecture IDs.")
        }

        guard let lecture = try store.loadCourseLectures().first(where: { $0.id == lectureID }) else {
            throw MCPError.notFound("Lecture not found: \(lectureID). Call get_course to see valid lecture IDs.")
        }

        let paperAssociations = try lecturePaperAssociations(lectureID: lectureID, store: store)

        let courseMetadata = try store.loadCourseGroups()[lecture.courseName]
        let courseTitle = courseMetadata?.title ?? lecture.courseName
        let lectureTitle = Self.nilIfBlank(lecture.title ?? "") ?? "Lecture \(lecture.number)"
        var lines = [
            "Lecture papers (\(paperAssociations.count)):",
            // Named by title; the caller passed the lecture's id, and the
            // course's rides on its own line (Prompts.hiddenIDs).
            "Course: \(courseTitle)",
            "course_id: \(lecture.courseName)",
            "Lecture \(lecture.number): \(lectureTitle)",
        ]

        guard !paperAssociations.isEmpty else {
            lines.append("- None")
            lines.append(
                "Run find_lecture_papers to find the papers the lecture videos and readable course materials cite, then ingest_lecture_papers on the ones the learner chooses, or attach an existing paper source with add_paper_to_lecture."
            )
            return lines.joined(separator: "\n")
        }

        for (item, paper) in paperAssociations {
            var details = [
                "source_id: \(paper.id)",
                "item_id: \(item.id)",
                "role: \(item.role.rawValue)",
                Self.lecturePaperStanding(item),
                "state: \(paper.state.rawValue)",
                "status: \(paper.status.rawValue)",
            ]
            if let author = Self.nilIfBlank(paper.author ?? "") {
                details.append("authors: \(author)")
            }
            if let journal = Self.nilIfBlank(paper.journal ?? "") {
                details.append("venue: \(journal)")
            }
            if let year = Self.nilIfBlank(paper.publishedYear ?? "") {
                details.append("year: \(year)")
            }
            if let doi = Self.nilIfBlank(paper.doi ?? "") {
                details.append("doi: \(doi)")
            }
            if let url = Self.nilIfBlank(paper.url) {
                details.append("url: \(url)")
            }
            if let wordCount = paper.wordCount {
                details.append("words: \(wordCount)")
            }
            lines.append("- \(paper.title) (\(details.joined(separator: ", ")))")
        }
        lines.append("Use get_source_content with a source_id to read a paper.")
        return lines.joined(separator: "\n")
    }

    func lecturePaperAssociations(
        lectureID: String,
        store: KnowledgeStore
    ) throws -> [(CourseLectureItem, StudioArticle)] {
        let items = try store.loadCourseLectureItems()
            .filter { $0.lectureId == lectureID }
            .sorted {
                $0.sortIndex == $1.sortIndex ? $0.id < $1.id : $0.sortIndex < $1.sortIndex
            }
        var associations: [(CourseLectureItem, StudioArticle)] = []
        for item in items {
            guard let sourceID = item.sourceId,
                  let source = try store.loadSourceWithoutContent(sourceID),
                  source.sourceType == .paper else {
                continue
            }
            associations.append((item, source))
        }
        return associations
    }

    func lecturePaperPayload(item: CourseLectureItem, source: StudioArticle) -> [String: Any] {
        var payload: [String: Any] = [
            "source_id": source.id,
            "item_id": item.id,
            "title": source.title,
            "role": item.role.rawValue,
            "assigned_reading": item.role == .reading,
            "state": source.state.rawValue,
            "status": source.status.rawValue,
        ]
        if let author = cleanedOptional(source.author) { payload["authors"] = author }
        if let journal = cleanedOptional(source.journal) { payload["venue"] = journal }
        if let year = cleanedOptional(source.publishedYear) { payload["year"] = year }
        if let doi = cleanedOptional(source.doi) { payload["doi"] = doi }
        if let url = cleanedOptional(source.url) { payload["url"] = url }
        if let wordCount = source.wordCount { payload["word_count"] = wordCount }
        return payload
    }

    /// The single association write used by both the explicit add tool and the
    /// automatic lecture-ingest workflow. `role` is `reading` for assigned
    /// reading, which is a row of the course's path and quizzed with its
    /// lecture, and `reference` for a paper the lecture only cites, which opens
    /// from its video's Papers menu. A new association takes `role`; an existing
    /// one keeps its role unless `replacingRole` is set.
    func associatePaperSource(
        lectureID inputLectureID: String,
        sourceID inputSourceID: String,
        role: CourseLectureItemRole = .reading,
        replacingRole: Bool = false,
        store: KnowledgeStore
    ) throws -> CoursePaperAssociation {
        let lectureID = inputLectureID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = inputSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lectureID.isEmpty else {
            throw MCPError.invalidInput("lecture_id is required. Call get_course to see lecture IDs.")
        }
        guard !sourceID.isEmpty else {
            throw MCPError.invalidInput("source_id is required. Pass the ID of an existing paper source.")
        }

        guard let lecture = try store.loadCourseLectures().first(where: { $0.id == lectureID }) else {
            throw MCPError.notFound("Lecture not found: \(lectureID). Call get_course to see valid lecture IDs.")
        }
        guard let source = try store.loadSourceWithoutContent(sourceID) else {
            throw MCPError.notFound("Source not found: \(sourceID). Import the paper first, then pass its source_id.")
        }
        guard source.sourceType == .paper else {
            throw MCPError.invalidInput(
                "Source \(sourceID) is type \(source.sourceType.rawValue), not paper. Pass a paper source_id."
            )
        }
        guard source.status == .active else {
            throw MCPError.invalidInput(
                "Paper \(sourceID) is archived. Restore it before associating it with a course lecture."
            )
        }

        let existingItems = try store.loadCourseLectureItems().filter { $0.lectureId == lectureID }
        if var existing = existingItems.first(where: { $0.sourceId == sourceID }) {
            let changing = replacingRole && existing.role != role
            if changing {
                existing.role = role
                _ = try store.saveCourseLectureItem(existing)
            }
            return CoursePaperAssociation(
                lecture: lecture,
                source: source,
                item: existing,
                created: false,
                roleChanged: changing
            )
        }

        let item = CourseLectureItem(
            lectureId: lectureID,
            sourceId: sourceID,
            role: role,
            sortIndex: (existingItems.map(\.sortIndex).max() ?? -1) + 1
        )
        _ = try store.saveCourseLectureItem(item)
        return CoursePaperAssociation(
            lecture: lecture,
            source: source,
            item: item,
            created: true
        )
    }

    /// Attach an existing canonical paper source to a lecture. CourseLectureItem
    /// is the one durable lecture-material relationship, so this automatically
    /// follows the existing course CloudKit and Notebook-link sync paths.
    ///
    /// `assignedReading` false files the paper as one the lecture only cites;
    /// nil leaves an existing association's role alone and makes a new one
    /// assigned reading.
    func addPaperToLecture(
        lectureID inputLectureID: String,
        sourceID inputSourceID: String,
        assignedReading: Bool? = nil
    ) throws -> String {
        let store = try knowledgeStore()
        let association = try associatePaperSource(
            lectureID: inputLectureID,
            sourceID: inputSourceID,
            role: assignedReading == false ? .reference : .reading,
            replacingRole: assignedReading != nil,
            store: store
        )
        // The sentence names the paper and the lecture; the caller passed
        // their ids, and the new item's rides on its own line
        // (Prompts.hiddenIDs).
        let ids = "item_id: \(association.item.id), \(Self.lecturePaperStanding(association.item))"
        if association.roleChanged {
            return "'\(association.source.title)' on lecture \(association.lecture.number) is now \(association.item.role == .reading ? "assigned reading" : "only cited").\n\(ids)"
        }
        if !association.created {
            return "'\(association.source.title)' is already associated with lecture \(association.lecture.number).\n\(ids)"
        }

        let courseTitle = try store.loadCourseGroups()[association.lecture.courseName]?.title
            ?? association.lecture.courseName
        return "Associated paper '\(association.source.title)' with lecture \(association.lecture.number) in '\(courseTitle)'.\ncourse_id: \(association.lecture.courseName), \(ids)"
    }

    /// How a lecture paper stands, for tool output: assigned reading has a row
    /// in the course and is quizzed; a cited paper opens from the video.
    static func lecturePaperStanding(_ item: CourseLectureItem) -> String {
        item.role == .reading ? "assigned_reading: true" : "assigned_reading: false (only cited)"
    }

    /// Split long course material into overlapping model-sized reads. The overlap
    /// keeps a citation that straddles a boundary intact; the explicit exhaustive
    /// workflow scans every chunk rather than silently truncating the document.
    static func lectureMaterialChunks(
        _ content: String,
        maxCharacters: Int = 24_000,
        overlapCharacters: Int = 1_200
    ) -> [String] {
        SlideCitationService.materialChunks(
            content,
            maxCharacters: maxCharacters,
            overlapCharacters: overlapCharacters
        )
    }

    /// Load material text without doing file I/O on the caller's executor. Most
    /// sources already have persisted content, which the caller reads in its store
    /// stretch and passes as `stored`; the local-file path covers older course PDFs
    /// whose text was indexed but not written back to source_content.
    func lectureMaterialText(
        _ source: StudioArticle,
        stored: String?
    ) async -> String? {
        if let stored {
            return stored
        }
        let localPath = cleanedOptional(source.localFilePath)
            ?? (source.url.hasPrefix("/") ? source.url : nil)
        guard let localPath else { return nil }
        let pages = source.bookPages
        let extractionTask = Task.detached(priority: .utility) {
            Self.extractTextFromLocalFile(localPath, pages: pages)
                .flatMap(Self.nilIfBlank)
        }
        return await extractionTask.value
    }

    /// A lecture source's stored text, read in a shared stretch of the store gate.
    private func storedLectureText(_ sourceID: String) async throws -> String? {
        try await withStoreGate(.shared) {
            cleanedOptional(try knowledgeStore().loadSourceContent(sourceID))
        }
    }

    /// The lecture's non-paper materials: the videos whose slides and transcripts are
    /// read, and every other attached source read as text. Papers are left out
    /// because they are what discovery produces, not what it reads.
    func lectureDiscoveryMaterials(
        lectureID: String,
        store: KnowledgeStore
    ) throws -> (videos: [StudioArticle], textMaterials: [StudioArticle]) {
        let lectureItems = try store.loadCourseLectureItems()
            .filter { $0.lectureId == lectureID }
            .sorted {
                $0.sortIndex == $1.sortIndex ? $0.id < $1.id : $0.sortIndex < $1.sortIndex
            }
        var videos: [StudioArticle] = []
        var textMaterials: [StudioArticle] = []
        var seenSourceIDs = Set<String>()
        for item in lectureItems {
            guard let sourceID = item.sourceId,
                  seenSourceIDs.insert(sourceID).inserted,
                  let source = try store.loadSourceWithoutContent(sourceID),
                  source.status == .active else {
                continue
            }
            if source.sourceType == .video {
                videos.append(source)
            } else if source.sourceType != .paper {
                textMaterials.append(source)
            }
        }
        return (videos, textMaterials)
    }

    func requireLecture(_ input: String, store: KnowledgeStore) throws -> CourseSession {
        let lectureID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lectureID.isEmpty else {
            throw MCPError.invalidInput("lecture_id is required. Call get_course to see lecture IDs.")
        }
        guard let lecture = try store.loadCourseLectures().first(where: { $0.id == lectureID }) else {
            throw MCPError.notFound("Lecture not found: \(lectureID). Call get_course to see valid lecture IDs.")
        }
        return lecture
    }

    /// How strongly a candidate's status speaks for the paper when the same paper was
    /// recorded under two of the lecture's materials: a decision (imported, dismissed)
    /// outranks an open offer, and an open offer outranks a failed lookup.
    static func lectureCandidateRank(_ status: VideoCitedPaper.Status) -> Int {
        switch status {
        case .imported: return 0
        case .dismissed: return 1
        case .pending: return 2
        case .unresolved: return 3
        }
    }

    /// The order the found list reads in: open offers first, since they are what the
    /// learner is being asked about, then what is already held, then what cannot be
    /// imported, then what was waved off.
    static func lectureCandidateListOrder(_ status: VideoCitedPaper.Status) -> Int {
        switch status {
        case .pending: return 0
        case .imported: return 1
        case .unresolved: return 2
        case .dismissed: return 3
        }
    }

    /// Find the papers cited by the videos and text materials attached to one lecture
    /// and record each as a candidate on the material it was read from. Nothing is
    /// imported and nothing is attached to the lecture: that is `ingestLecturePapers`,
    /// run on the candidates the learner picks.
    ///
    /// The minutes of transcript fetches, slide scans and model reads hold no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the lecture is read in shared stretches,
    /// the video tools save what they found in stretches of their own, and each
    /// material's candidates are recorded in one stretch held alone.
    func findLecturePapers(lectureID input: String, force: Bool) async throws -> String {
        let store = try knowledgeStore()
        let (lecture, videos, textMaterials, storedTexts) = try await withStoreGate(.shared) {
            let found = try requireLecture(input, store: store)
            let materials = try lectureDiscoveryMaterials(lectureID: found.id, store: store)
            var texts: [String: String] = [:]
            for material in materials.textMaterials {
                texts[material.id] = cleanedOptional(try store.loadSourceContent(material.id))
            }
            return (found, materials.videos, materials.textMaterials, texts)
        }
        let lectureID = lecture.id

        var readableMaterials: [(source: StudioArticle, content: String)] = []
        var materialSourceIDsWithoutContent: [String] = []
        for material in textMaterials {
            if let content = await lectureMaterialText(material, stored: storedTexts[material.id]) {
                readableMaterials.append((material, content))
            } else {
                materialSourceIDsWithoutContent.append(material.id)
            }
        }
        guard !videos.isEmpty || !readableMaterials.isEmpty else {
            throw MCPError.invalidInput(
                "Lecture \(lecture.number) has no readable active video, notes, syllabus, slides, or other text material to scan. Attach lecture material first, or associate known papers with add_paper_to_lecture."
            )
        }

        let (shouldScanVideoEvidenceByID, storedCourseTitle) = try await withStoreGate(.shared) {
            var shouldScan: [String: Bool] = [:]
            for video in videos {
                if force {
                    shouldScan[video.id] = true
                } else {
                    shouldScan[video.id] = try store.loadVideoCitedPapers(forSourceID: video.id).isEmpty
                }
            }
            return (shouldScan, try store.loadCourseGroups()[lecture.courseName]?.title)
        }
        let needsTextDiscovery = !readableMaterials.isEmpty
            || shouldScanVideoEvidenceByID.values.contains(true)
        let discoveryConfig: AITaskConfig?
        if needsTextDiscovery {
            guard let resolved = KeychainService.resolveConfig(for: .lecturePaperDiscovery) else {
                throw MCPError.invalidInput(
                    KeychainService.backgroundAIUnavailableMessage(for: .lecturePaperDiscovery)
                        ?? "Lecture Paper Discovery is not configured. Sign in to ForeverLM (Settings › Billing), or pin a model to the task with set_ai_task_settings."
                )
            }
            discoveryConfig = resolved
        } else {
            discoveryConfig = nil
        }

        let courseTitle = storedCourseTitle ?? lecture.courseName
        let lectureTitle = Self.nilIfBlank(lecture.title ?? "")
            ?? "Lecture \(lecture.number)"
        let lectureContext = """
        Course: \(courseTitle)
        Lecture \(lecture.number): \(lectureTitle)
        """

        var scansPerformed = 0
        var transcriptsFetched = 0
        var materialChunksScanned = 0
        var readableVideoTranscripts: [(source: StudioArticle, content: String)] = []
        var videoSourceIDsWithoutTranscript: [String] = []
        // A video whose slides could not be read is reported and the rest of the lecture
        // is still read, so one missing storyboard never hides what the notes cite.
        var videoScanProblems: [String] = []

        for video in videos where shouldScanVideoEvidenceByID[video.id] == true {
            do {
                if try await storedLectureText(video.id) == nil {
                    _ = try await fetchVideoTranscript(sourceID: video.id)
                    transcriptsFetched += 1
                }
                let report = try await scanVideoForCitedPapers(
                    sourceID: video.id,
                    force: force,
                    exhaustive: true
                )
                scansPerformed += 1
                if let data = report.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let warning = object["warning"] as? String {
                    videoScanProblems.append("\(Self.sourceLink(title: video.title, id: video.id)): \(warning)")
                }
            } catch {
                videoScanProblems.append(
                    "\(Self.sourceLink(title: video.title, id: video.id)): its slides were not read: \(error.localizedDescription)"
                )
            }
            if let transcript = try await storedLectureText(video.id) {
                readableVideoTranscripts.append((video, transcript))
            } else {
                videoSourceIDsWithoutTranscript.append(video.id)
            }
        }

        let materialSources = videos + textMaterials
        let materialSourceIDs = materialSources.map(\.id)

        // One row per paper per lecture: a paper the slides already recorded is not
        // recorded again from the notes that cite it too. Read again before each
        // material's candidates are recorded, so a row another call wrote while the
        // model read is kept as it is.
        func recordedLectureKeys() throws -> Set<String> {
            Set(
                try materialSourceIDs.flatMap { try store.loadVideoCitedPapers(forSourceID: $0) }
                    .map(\.dedupKey)
            )
        }
        var lectureKeys = try await withStoreGate(.shared) { try recordedLectureKeys() }
        var textCandidatesFound = 0
        var textCandidatesAdded = 0
        let textDiscoveryInputs = readableMaterials + readableVideoTranscripts
        if !textDiscoveryInputs.isEmpty {
            guard let discoveryConfig else {
                throw MCPError.invalidInput("Lecture Paper Discovery is not configured.")
            }
            let aiService = AIService()
            for (material, content) in textDiscoveryInputs {
                let chunks = Self.lectureMaterialChunks(content)
                materialChunksScanned += chunks.count
                var citations: [SlideCitationService.ExtractedCitation] = []
                for chunk in chunks {
                    citations += try await aiService.discoverLecturePaperCitations(
                        materialTitle: material.title,
                        lectureContext: lectureContext,
                        content: chunk,
                        config: discoveryConfig
                    )
                }
                let resolved = await SlideCitationService.shared.resolveExtractedCitations(
                    citations,
                    sourceID: material.id,
                    sourceText: content,
                    context: lectureContext,
                    aiService: aiService
                )
                textCandidatesFound += resolved.count
                try await withStoreGate(.exclusive) {
                    lectureKeys.formUnion(try recordedLectureKeys())
                    for var candidate in resolved where lectureKeys.insert(candidate.dedupKey).inserted {
                        // A paper already in the library is recorded as held, the same as
                        // every other scan does, so it is never offered for import twice.
                        if let url = cleanedOptional(candidate.url),
                           let existingSourceID = try importedPaperSourceID(
                               for: candidate,
                               url: url,
                               store: store
                           ) {
                            candidate.status = .imported
                            candidate.importedSourceID = existingSourceID
                        }
                        try store.saveVideoCitedPaper(candidate)
                        textCandidatesAdded += 1
                    }
                }
            }
        }

        let titlesBySourceID = Dictionary(
            materialSources.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let (attachedSourceIDs, allRows) = try await withStoreGate(.shared) {
            let attached = Set(
                try lecturePaperAssociations(lectureID: lectureID, store: store).map { $0.1.id }
            )
            return (attached, try materialSourceIDs.flatMap { try store.loadVideoCitedPapers(forSourceID: $0) })
        }
        var rowsByKey: [String: [VideoCitedPaper]] = [:]
        var keyOrder: [String] = []
        for row in allRows {
            if rowsByKey[row.dedupKey] == nil { keyOrder.append(row.dedupKey) }
            rowsByKey[row.dedupKey, default: []].append(row)
        }
        let representatives = keyOrder.compactMap { key -> (paper: VideoCitedPaper, rows: [VideoCitedPaper])? in
            guard let rows = rowsByKey[key],
                  let representative = rows.min(by: {
                      Self.lectureCandidateRank($0.status) < Self.lectureCandidateRank($1.status)
                  }) else { return nil }
            return (paper: representative, rows: rows)
        }
        .sorted {
            let lhs = Self.lectureCandidateListOrder($0.paper.status)
            let rhs = Self.lectureCandidateListOrder($1.paper.status)
            return lhs == rhs ? $0.paper.createdAt < $1.paper.createdAt : lhs < rhs
        }

        var attachedCount = 0
        let candidatePayloads: [[String: Any]] = representatives.map { entry in
            var payload = citedPaperPayload(entry.paper)
            var foundIn: [String] = []
            for row in entry.rows {
                let label = titlesBySourceID[row.sourceID] ?? row.sourceID
                if !foundIn.contains(label) { foundIn.append(label) }
            }
            payload["found_in"] = foundIn
            let attached = cleanedOptional(entry.paper.importedSourceID)
                .map { attachedSourceIDs.contains($0) } ?? false
            if attached { attachedCount += 1 }
            payload["attached_to_lecture"] = attached
            return payload
        }
        let reported = representatives.map(\.paper)
        let pendingCount = reported.filter { $0.status == .pending }.count
        let heldNotAttached = reported.filter {
            $0.status == .imported
                && !(cleanedOptional($0.importedSourceID).map { attachedSourceIDs.contains($0) } ?? false)
        }.count

        var payload: [String: Any] = [
            "course_id": lecture.courseName,
            "course_title": courseTitle,
            "lecture_id": lecture.id,
            "lecture_number": lecture.number,
            "lecture_title": lectureTitle,
            "videos_considered": videos.count,
            "video_source_ids": videos.map(\.id),
            "text_materials_considered": textMaterials.count,
            "text_materials_read": readableMaterials.count,
            "text_material_source_ids": readableMaterials.map { $0.source.id },
            "text_materials_without_content": materialSourceIDsWithoutContent,
            "video_transcripts_read": readableVideoTranscripts.count,
            "video_transcripts_without_content": videoSourceIDsWithoutTranscript,
            "material_chunks_scanned": materialChunksScanned,
            "transcripts_fetched": transcriptsFetched,
            "scans_performed": scansPerformed,
            "force_rescan": force,
            "text_candidates_found": textCandidatesFound,
            "text_candidates_added": textCandidatesAdded,
            "candidate_count": reported.count,
            "counts_by_status": citedPaperStatusCounts(reported),
            "attached_to_lecture_count": attachedCount,
            "candidates": candidatePayloads,
            "guidance": "Nothing was imported or attached. Show the learner these candidates and call ingest_lecture_papers with the cited_paper_ids they choose: a pending one is imported and attached, an imported one that is not yet attached_to_lecture is attached. Attached papers are only cited: they open from the lecture video's Papers menu, not as course rows, and are not quizzed. Put a paper in assigned_reading_ids only when reading it is actually necessary for the course (the syllabus or lecturer assigns it, the lecture is built on it, or the learner asks), never merely because a slide cites it. unresolved ones matched no paper record and can only be dismissed. Dismiss or restore with update_video_cited_paper_status.",
        ]
        payload["message"] = "Found \(reported.count) paper candidate\(reported.count == 1 ? "" : "s") across \(videos.count) lecture video\(videos.count == 1 ? "" : "s") and \(readableMaterials.count) text material\(readableMaterials.count == 1 ? "" : "s") for lecture \(lecture.number): \(pendingCount) can be imported, \(heldNotAttached) \(heldNotAttached == 1 ? "is" : "are") already in the library but not attached, and \(attachedCount) \(attachedCount == 1 ? "is" : "are") already attached."
        if !videoScanProblems.isEmpty {
            payload["warning"] = "Not every lecture video was fully read, so the lecture may cite papers that are not listed here."
            payload["video_scan_problems"] = videoScanProblems
        }
        return try jsonString(payload)
    }

    /// Import the chosen lecture candidates through the normal paper pipeline and
    /// attach the resulting canonical sources to the lecture. Candidates come from
    /// `findLecturePapers`; nothing is discovered here.
    ///
    /// A paper is attached as one the lecture only cites, off the course's path,
    /// unless its id is also in `assignedReadingIDs`: it is attached, or turned
    /// into, assigned reading.
    func ingestLecturePapers(
        lectureID input: String,
        citedPaperIDs rawIDs: [String],
        assignedReadingIDs rawAssignedIDs: [String] = []
    ) async throws -> String {
        let store = try knowledgeStore()
        let lecture = try requireLecture(input, store: store)
        let lectureID = lecture.id

        var citedPaperIDs: [String] = []
        for rawID in rawIDs {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !citedPaperIDs.contains(id) { citedPaperIDs.append(id) }
        }
        guard !citedPaperIDs.isEmpty else {
            throw MCPError.invalidInput(
                "cited_paper_ids is required. Call find_lecture_papers with this lecture_id, show the learner the candidates, and pass the cited_paper_id of each one they choose."
            )
        }

        let assignedReadingIDs = Set(rawAssignedIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if let stray = assignedReadingIDs.first(where: { !$0.isEmpty && !citedPaperIDs.contains($0) }) {
            throw MCPError.invalidInput(
                "assigned_reading_ids must be a subset of cited_paper_ids; \(stray) is not in cited_paper_ids."
            )
        }

        let (videos, textMaterials) = try lectureDiscoveryMaterials(lectureID: lectureID, store: store)
        let materialSourceIDs = Set((videos + textMaterials).map(\.id))

        // Every id is checked before anything is downloaded, so a mistyped id never
        // leaves the lecture half-ingested.
        var requested: [VideoCitedPaper] = []
        for id in citedPaperIDs {
            guard let paper = try store.loadVideoCitedPaper(id: id) else {
                throw MCPError.notFound(
                    "Cited paper not found: \(id). Call find_lecture_papers with lecture_id \(lectureID) to see valid cited_paper_ids."
                )
            }
            guard materialSourceIDs.contains(paper.sourceID) else {
                throw MCPError.invalidInput(
                    "Cited paper \(id) ('\(paper.title)') was not found in the materials of lecture \(lecture.number). Call find_lecture_papers with lecture_id \(lectureID) to see this lecture's candidates."
                )
            }
            requested.append(paper)
        }

        var newlyImportedSourceIDs = Set<String>()
        var newlyAssociatedSourceIDs = Set<String>()
        var attached: [[String: Any]] = []
        var skipped: [[String: Any]] = []
        var failed: [[String: Any]] = []

        for paper in requested {
            let reference: [String: Any] = ["cited_paper_id": paper.id, "title": paper.title]
            do {
                // Whether the library held the paper before this call, which is what
                // separates a new library paper from one that was only attached.
                let wasInLibrary: Bool
                switch paper.status {
                case .dismissed:
                    skipped.append(reference.merging([
                        "status": paper.status.rawValue,
                        "reason": "Dismissed. Restore it with update_video_cited_paper_status first if the learner wants it.",
                    ]) { $1 })
                    continue
                case .unresolved:
                    skipped.append(reference.merging([
                        "status": paper.status.rawValue,
                        "reason": "No paper record was matched, so there is nothing to download. Add it by hand with import_paper_from_url, or dismiss it.",
                    ]) { $1 })
                    continue
                case .pending:
                    guard let url = cleanedOptional(paper.url) else {
                        skipped.append(reference.merging([
                            "status": paper.status.rawValue,
                            "reason": "No address was resolved for it, so there is nothing to download.",
                        ]) { $1 })
                        continue
                    }
                    wasInLibrary = try importedPaperSourceID(for: paper, url: url, store: store) != nil
                    _ = try await importVideoCitedPaper(citedPaperID: paper.id)
                case .imported:
                    wasInLibrary = true
                }

                guard var imported = try store.loadVideoCitedPaper(id: paper.id) else {
                    throw MCPError.notFound(
                        "Paper candidate \(paper.id) disappeared after import; the lecture association was not completed."
                    )
                }
                if imported.importedSourceID == nil,
                   let url = cleanedOptional(imported.url),
                   let resolvedSourceID = try importedPaperSourceID(
                       for: imported,
                       url: url,
                       store: store
                   ) {
                    imported.importedSourceID = resolvedSourceID
                    imported.updatedAt = Date()
                    try store.saveVideoCitedPaper(imported)
                }
                guard let importedSourceID = cleanedOptional(imported.importedSourceID) else {
                    throw MCPError.invalidInput(
                        "'\(imported.title)' is in the library, but its library source could not be identified, so it was not attached to lecture \(lecture.number)."
                    )
                }
                if !wasInLibrary {
                    newlyImportedSourceIDs.insert(importedSourceID)
                }
                // The product owner, 2026-09-27: a paper goes under the course "only if
                // we deem it worth while that reading a paper is ACTUALLY
                // necessary as assigned reading; but if it's just a citation on
                // one of the slides, then no need". A re-ingest never demotes.
                let assigned = assignedReadingIDs.contains(paper.id)
                let association = try associatePaperSource(
                    lectureID: lectureID,
                    sourceID: importedSourceID,
                    role: assigned ? .reading : .reference,
                    replacingRole: assigned,
                    store: store
                )
                if association.created {
                    newlyAssociatedSourceIDs.insert(importedSourceID)
                }
                attached.append(reference.merging([
                    "source_id": importedSourceID,
                    "newly_imported": !wasInLibrary,
                    "newly_attached": association.created,
                    "assigned_reading": association.item.role == .reading,
                ]) { $1 })

                // The same paper recorded under another of the lecture's materials is
                // satisfied by this import too, so the next find does not offer it again.
                for materialID in materialSourceIDs where materialID != imported.sourceID {
                    for var sibling in try store.loadVideoCitedPapers(forSourceID: materialID)
                    where sibling.dedupKey == imported.dedupKey
                        && (sibling.status == .pending || sibling.status == .unresolved) {
                        sibling.status = .imported
                        sibling.importedSourceID = importedSourceID
                        sibling.updatedAt = Date()
                        try store.saveVideoCitedPaper(sibling)
                    }
                }
            } catch {
                failed.append(reference.merging(["error": error.localizedDescription]) { $1 })
            }
        }

        let courseTitle = try store.loadCourseGroups()[lecture.courseName]?.title
            ?? lecture.courseName
        let lectureTitle = Self.nilIfBlank(lecture.title ?? "")
            ?? "Lecture \(lecture.number)"
        let finalAssociations = try lecturePaperAssociations(lectureID: lectureID, store: store)
        var payload: [String: Any] = [
            "course_id": lecture.courseName,
            "course_title": courseTitle,
            "lecture_id": lecture.id,
            "lecture_number": lecture.number,
            "lecture_title": lectureTitle,
            "requested_count": requested.count,
            "attached": attached,
            "new_library_papers": newlyImportedSourceIDs.count,
            "new_lecture_associations": newlyAssociatedSourceIDs.count,
            "skipped": skipped,
            "failed": failed,
            "associated_paper_count": finalAssociations.count,
            "papers": finalAssociations.map {
                lecturePaperPayload(item: $0.0, source: $0.1)
            },
        ]
        payload["message"] = "Of \(requested.count) chosen candidate\(requested.count == 1 ? "" : "s"), imported \(newlyImportedSourceIDs.count) new paper\(newlyImportedSourceIDs.count == 1 ? "" : "s") and attached \(newlyAssociatedSourceIDs.count) to lecture \(lecture.number), which now has \(finalAssociations.count) paper\(finalAssociations.count == 1 ? "" : "s")."
        if !skipped.isEmpty || !failed.isEmpty {
            payload["warning"] = "\(skipped.count) candidate\(skipped.count == 1 ? " was" : "s were") skipped and \(failed.count) failed; see skipped and failed for why."
        }
        return try jsonString(payload)
    }

    func createCourse(
        title: String,
        courseCode: String?,
        institution: String?,
        instructors: String?,
        notebookID: String? = nil
    ) throws -> String {
        let store = try knowledgeStore()
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayTitle.isEmpty else {
            throw MCPError.invalidInput("title is required.")
        }
        // The Notebook that follows it, checked before the course is made. A
        // new course is My Library's, so a Notebook that follows it is too.
        let notebook = try notebookForMadeThing(notebookID: notebookID, store: store)
        if let notebook, notebook.teamID != nil {
            throw MCPError.invalidInput(
                "‘\(notebook.title)’ is a team's Notebook. A course made here is My Library's, so only a Notebook of My Library follows it: pass one from list_notebooks, or leave notebook_id out."
            )
        }

        do {
            let existingID = try resolveExistingCourseID(
                input: displayTitle,
                store: store,
                preferStableID: false
            )
            let metadata = try store.loadCourseGroups()[existingID] ?? CourseMetadata(title: existingID)
            let candidate = Self.courseCandidateLabel(courseID: existingID, metadata: metadata)
            throw MCPError.invalidInput(
                "A course matching '\(displayTitle)' already exists: \(candidate). Reuse its stable course_id from list_courses."
            )
        } catch let error as MCPError {
            switch error {
            case .notFound:
                break
            default:
                throw error
            }
        }

        let courseID = UUID().uuidString
        let metadata = CourseMetadata(
            courseCode: Self.nilIfBlank(courseCode ?? ""),
            title: displayTitle,
            institution: Self.nilIfBlank(institution ?? ""),
            instructors: Self.nilIfBlank(instructors ?? "")
        )
        try store.saveCourseGroup(name: courseID, metadata: metadata)
        guard let notebook else {
            return "Created course '\(displayTitle)'.\ncourse_id: \(courseID)\nnotebook_id_applied: none — no Notebook follows it. A course lives in no Notebook."
        }
        try store.followCourse(courseID: courseID, notebookID: notebook.id)
        return "Created course '\(displayTitle)'.\ncourse_id: \(courseID)\nnotebook_id_applied: \(notebook.id) — Notebook ‘\(notebook.title)’ follows it, so the sources its lectures gain join that Notebook. The course itself lives in no Notebook."
    }

    // MARK: - Playlist import

    /// Import a YouTube playlist as a course the way pasting its link in the app
    /// does: `StudioViewModel.importYouTubePlaylist` makes the course under a
    /// stable ID, adds every video as a `video` source on its own numbered
    /// lecture, fills the course metadata from the playlist, and fetches the
    /// transcripts. The playlist page itself is never a source.
    ///
    /// Before this tool an assistant asked to "ingest this playlist course" had
    /// only add_source, and assembled the course by hand (2026-09-13): the
    /// playlist page went in as a course source, the course took its title as
    /// its ID, and lessons were typed `course` rather than `video` — three of
    /// them were still wrong two weeks later. add_source now refuses a playlist
    /// URL and names this tool instead.
    ///
    /// A playlist some course already names is imported into that course, so
    /// running this twice fills gaps instead of standing up a second copy.
    func importYouTubePlaylistMCP(url rawURL: String, courseID rawCourseID: String?, notebookID: String? = nil) async throws -> String {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubePlaylistService.isPlaylistURL(url) else {
            throw MCPError.invalidInput(
                "url must be a YouTube playlist address (youtube.com/playlist?list=…). For a single video use add_source with source_type video."
            )
        }
        let store = try knowledgeStore()
        // The notebook that follows the course, checked before anything is
        // imported.
        let notebook = try notebookForMadeThing(notebookID: notebookID, store: store)
        let explicitCourseID = Self.nilIfBlank(rawCourseID ?? "")
        let targetCourseID: String?
        if let explicitCourseID {
            targetCourseID = try requireExistingStableCourseID(input: explicitCourseID, store: store)
        } else {
            targetCourseID = Self.courseID(forPlaylistURL: url, in: try store.loadCourseGroups())
        }
        // A Notebook follows only a course of its own library: refused here,
        // not after the playlist was imported.
        try requireNotebook(notebook, takesCourse: targetCourseID, store: store)
        var payload = try await Self.importYouTubePlaylistLikeThePasteField(url: url, intoCourse: targetCourseID)
        try await fileImportedCourse(in: notebook, payload: &payload)
        return try jsonString(payload)
    }

    /// A course import's notebook_id, once the course exists: that Notebook
    /// follows the course (`fileCourse`). The answer says so under
    /// `notebook_id_applied`.
    private func fileImportedCourse(in notebook: LearningGoalRecord?, payload: inout [String: Any]) async throws {
        guard let notebook else { return }
        guard let courseID = payload["course_id"] as? String else { return }
        do {
            let filing = try await fileCourse(courseID, inNotebook: notebook)
            payload["notebook_id_applied"] = filing.applied
            payload["notebook_note"] = filing.note
        } catch {
            payload["notebook_id_applied"] = "none"
            payload["notebook_note"] = "The course was imported but Notebook ‘\(notebook.title)’ does not follow it: \(error.localizedDescription)"
        }
    }

    /// The course a playlist already belongs to: the one whose stored playlist
    /// has the same `list` id, whatever else differs in the address. Nil when
    /// no course names it, or when more than one does (the caller then makes a
    /// new course rather than guessing between two).
    static func courseID(forPlaylistURL url: String, in groups: [String: CourseMetadata]) -> String? {
        guard let listID = YouTubePlaylistService.extractPlaylistId(from: url) else { return nil }
        let matches = groups
            .filter { $0.value.playlistURL.flatMap(YouTubePlaylistService.extractPlaylistId(from:)) == listID }
            .map(\.key)
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor
    private static func importYouTubePlaylistLikeThePasteField(url: String, intoCourse: String?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        if let intoCourse, studio.isImportingCourse(intoCourse) {
            throw MCPError.invalidInput(
                "\(studio.courseDisplayName(intoCourse)) is importing already; call get_course with course_id \(intoCourse) once it finishes."
            )
        }
        studio.errorMessage = nil
        guard let courseID = await studio.importYouTubePlaylist(url: url, intoCourse: intoCourse) else {
            throw MCPError.invalidInput(studio.errorMessage ?? "No video from that playlist could be added.")
        }
        let lectures = studio.courseLectures(for: courseID)
        let videoIDs = Set(lectures
            .flatMap { studio.courseLectureItems(for: $0.id) }
            .filter { $0.role == .video }
            .compactMap(\.sourceId))
        let videos = studio.articles.filter { videoIDs.contains($0.id) }
        let withTranscript = videos.filter { $0.content?.isEmpty == false }.count
        let title = studio.courseDisplayName(courseID)
        var payload: [String: Any] = [
            "course_id": courseID,
            "title": title,
            "into_existing_course": intoCourse != nil,
            "lectures": lectures.count,
            "videos": videos.count,
            "videos_with_transcript": withTranscript,
            "message": "Imported “\(title)”: \(lectures.count) lecture\(lectures.count == 1 ? "" : "s"), each holding its video; \(withTranscript) of \(videos.count) transcript\(videos.count == 1 ? "" : "s") fetched. Call get_course with this course_id for the outline.",
        ]
        if let warning = studio.errorMessage { payload["warning"] = warning }
        return payload
    }

    /// Import a Teachable course from one of its lecture links the way the app
    /// does (`StudioViewModel.importTeachableCourse`): the outline read from
    /// the lecture page, one video source per video lecture, transcripts made
    /// from the audio afterwards. Returns once the lectures are filed.
    func importTeachableCourseMCP(url rawURL: String, courseID rawCourseID: String?, notebookID: String? = nil) async throws -> String {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeachableCourseService.isLectureURL(url) else {
            throw MCPError.invalidInput(
                "url must be a Teachable lecture address (…/courses/<course>/lectures/<id>). Open any lecture of the course and pass its address."
            )
        }
        let store = try knowledgeStore()
        let notebook = try notebookForMadeThing(notebookID: notebookID, store: store)
        let targetCourseID = try Self.nilIfBlank(rawCourseID ?? "").map {
            try requireExistingStableCourseID(input: $0, store: store)
        }
        // Before the outline is read and any lecture is transcribed (paid).
        try requireNotebook(notebook, takesCourse: targetCourseID, store: store)
        var payload = try await Self.importTeachableCourseLikeThePasteField(url: url, intoCourse: targetCourseID)
        try await fileImportedCourse(in: notebook, payload: &payload)
        return try jsonString(payload)
    }

    @MainActor
    private static func importTeachableCourseLikeThePasteField(url: String, intoCourse: String?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        if let intoCourse, studio.isImportingCourse(intoCourse) {
            throw MCPError.invalidInput(
                "\(studio.courseDisplayName(intoCourse)) is importing already; call get_course with course_id \(intoCourse) once it finishes."
            )
        }
        studio.errorMessage = nil
        guard let courseID = await studio.importTeachableCourse(url: url, intoCourse: intoCourse, waitForTranscripts: false) else {
            throw MCPError.invalidInput(studio.errorMessage ?? "No lecture of that course could be added.")
        }
        let lectures = studio.courseLectures(for: courseID)
        let videoIDs = Set(lectures
            .flatMap { studio.courseLectureItems(for: $0.id) }
            .filter { $0.role == .video }
            .compactMap(\.sourceId))
        let title = studio.courseDisplayName(courseID)
        // In lecture order, so the first lectures are ready first.
        let orderedVideoIDs = lectures
            .flatMap { studio.courseLectureItems(for: $0.id) }
            .filter { $0.role == .video }
            .compactMap(\.sourceId)
        var seen = Set<String>()
        let pending = orderedVideoIDs.filter { id in
            seen.insert(id).inserted && studio.articles.first { $0.id == id }?.content == nil
        }
        var payload: [String: Any] = [
            "course_id": courseID,
            "title": title,
            "into_existing_course": intoCourse != nil,
            "lectures": lectures.count,
            "videos": videoIDs.count,
            "video_source_ids": Array(videoIDs).sorted(),
            "message": "Imported “\(title)”: \(lectures.count) lecture\(lectures.count == 1 ? "" : "s"), each holding its video. Transcripts are being made from the audio now, a few minutes per lecture; call get_source_content on a video_source_id (or fetch_video_transcript) to read one when it is ready.",
        ]
        if !pending.isEmpty {
            // Speech-to-text is paid, minutes a lecture: the learner can stop
            // the rest with cancel_ai_work and this work_id.
            payload["work_id"] = MCPRunningWork.shared.startBackground(
                tool: "import_teachable_course",
                about: "transcripts of \(pending.count) lecture\(pending.count == 1 ? "" : "s") of \(title)"
            ) { @MainActor in
                await studio.transcribeTeachableLectures(pending)
            }
            payload["transcripts_pending"] = pending.count
        }
        if let warning = studio.errorMessage { payload["warning"] = warning }
        return payload
    }

    /// Start a Teachable lecture's transcript in the app and answer at once:
    /// the audio download and speech-to-text outlast a tool call. Returns the
    /// work id `cancel_ai_work` stops it by.
    @MainActor
    static func startTeachableTranscript(sourceID: String) throws -> String {
        let studio = try AppModelBridge.requireStudio()
        return MCPRunningWork.shared.startBackground(tool: "fetch_video_transcript", about: "source_id \(sourceID)") { @MainActor in
            await studio.transcribeTeachableLectures([sourceID])
        }
    }

    func updateCourse(
        courseID input: String,
        title: String?,
        courseCode: String?,
        institution: String?,
        instructors: String?,
        playlistURL: String?,
        notebookID: String? = nil,
        unlinkNotebookID: String? = nil
    ) throws -> String {
        let store = try knowledgeStore()
        let courseID = try requireExistingStableCourseID(input: input, store: store)
        var metadata = try store.loadCourseGroups()[courseID] ?? CourseMetadata(title: courseID)
        var changedFields: [String] = []
        // notebook_id makes a Notebook follow the course, unlink_notebook_id
        // stops one (docs/courses-design.md): a course lives in no Notebook.
        // Checked before anything is written. A blank value is an unused slot
        // (models fill those with ""), not a request.
        var follow: LearningGoalRecord?
        if let notebookID, Self.nilIfBlank(notebookID) != nil {
            follow = try notebookForMadeThing(notebookID: notebookID, store: store)
        }
        var unlink: LearningGoalRecord?
        if let unlinkNotebookID, let unlinkID = Self.nilIfBlank(unlinkNotebookID) {
            guard let found = try store.loadLearningGoal(unlinkID), found.isNotebook else {
                throw MCPError.invalidInput("Notebook not found: \(unlinkID). Use list_notebooks to see available Notebooks.")
            }
            unlink = found
        }

        if let title {
            let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayTitle.isEmpty else {
                throw MCPError.invalidInput("title cannot be empty.")
            }
            metadata.title = displayTitle
            changedFields.append("title")
        }
        if let courseCode {
            metadata.courseCode = Self.nilIfBlank(courseCode)
            changedFields.append("course_code")
        }
        if let institution {
            metadata.institution = Self.nilIfBlank(institution)
            changedFields.append("institution")
        }
        if let instructors {
            metadata.instructors = Self.nilIfBlank(instructors)
            changedFields.append("instructors")
        }
        if let playlistURL {
            metadata.playlistURL = Self.nilIfBlank(playlistURL)
            changedFields.append("playlist_url")
        }
        guard !changedFields.isEmpty || follow != nil || unlink != nil else {
            throw MCPError.invalidInput(
                "Provide at least one of: title, course_code, institution, instructors, playlist_url, notebook_id, unlink_notebook_id."
            )
        }

        // The link first: the store refuses a Notebook of another library, or
        // a team's course this account can only read, before anything is
        // written, so a refused link leaves the metadata as it was too.
        let added = try follow.map { try store.followCourse(courseID: courseID, notebookID: $0.id) }
        let unlinked = try unlink.map { try store.unlinkCourseFromNotebook(goalID: $0.id, courseID: courseID) }
        if !changedFields.isEmpty {
            try store.saveCourseGroup(name: courseID, metadata: metadata)
        }
        let displayTitle = metadata.title ?? courseID
        var answer = changedFields.isEmpty
            ? "Course '\(displayTitle)'."
            : "Updated course '\(displayTitle)': \(changedFields.joined(separator: ", "))."
        if let notebook = follow, let added {
            let joined = added > 0 ? " \(added) of its source\(added == 1 ? "" : "s") joined it." : ""
            answer += " Notebook ‘\(notebook.title)’ follows the course now.\(joined) The course itself lives in no Notebook."
        }
        if let notebook = unlink, let unlinked {
            answer += unlinked
                ? " Notebook ‘\(notebook.title)’ no longer follows the course; it keeps the sources it holds."
                : " Notebook ‘\(notebook.title)’ did not follow the course."
        }
        return answer
    }

    /// Delete a course collection, keeping every source that has a library home
    /// of its own. Course-typed material had no home but the course, so it is
    /// hidden with it rather than left in the library where no list can show it;
    /// the Courses tab's hidden menu brings it back.
    /// Destructive course writes require the exact stable ID: a display title is
    /// never resolved implicitly at this boundary, even when it is currently
    /// unique, because titles are presentation metadata and can become ambiguous.
    func deleteCourse(courseID input: String) throws -> String {
        let store = try knowledgeStore()
        let courseID = try requireExistingStableCourseID(input: input, store: store)
        let groups = try store.loadCourseGroups()
        let lectures = try store.loadCourseLectures()
        let sources = try store.loadActiveSources()

        let title = groups[courseID]?.title ?? courseID
        let lectureIDs = Set(lectures.filter { $0.courseName == courseID }.map(\.id))
        let attachedSourceIDs = try store.loadCourseLectureItems()
            .filter { lectureIDs.contains($0.lectureId) }
            .compactMap(\.sourceId)
        let groupedSourceIDs = sources
            .filter { $0.sourceType == .course && $0.parentGroup == courseID }
            .map(\.id)
        let courseSourceIDs = Set(attachedSourceIDs).union(groupedSourceIDs)
        let hiddenSourceIDs = Set(try store.deleteCourseGroup(name: courseID))
        let preservedCount = courseSourceIDs.subtracting(hiddenSourceIDs).count
        let hiddenCount = hiddenSourceIDs.count
        var clauses: [String] = []
        if preservedCount > 0 {
            clauses.append(
                "Preserved \(preservedCount) source\(preservedCount == 1 ? "" : "s") in the library without a course assignment."
            )
        }
        if hiddenCount > 0 {
            clauses.append(
                "Hid \(hiddenCount) course source\(hiddenCount == 1 ? "" : "s") the course was the only home for; the Courses tab's hidden items list them."
            )
        }
        if clauses.isEmpty {
            clauses.append("It held no sources.")
        }
        return (["Deleted course '\(title)'."] + clauses).joined(separator: " ")
    }

    func createCourseLectureResolved(
        courseIdentifier: String,
        identifierIsStableID: Bool = false,
        title: String?,
        number: Int?
    ) throws -> String {
        let store = try knowledgeStore()
        let courseID = try resolveExistingCourseID(
            input: courseIdentifier,
            store: store,
            preferStableID: identifierIsStableID
        )
        let existing = try store.loadCourseLectures().filter { $0.courseName == courseID }
        let resolvedNumber = number ?? ((existing.map(\.number).max() ?? 0) + 1)
        guard resolvedNumber > 0 else {
            throw MCPError.invalidInput("number must be greater than zero.")
        }
        guard !existing.contains(where: { $0.number == resolvedNumber }) else {
            throw MCPError.invalidInput(
                "Course '\(try store.loadCourseGroups()[courseID]?.title ?? courseID)' already has lecture \(resolvedNumber). Call get_course and reuse or choose another lecture number."
            )
        }

        let lecture = CourseSession(
            courseName: courseID,
            number: resolvedNumber,
            title: Self.nilIfBlank(title ?? "")
        )
        try store.saveCourseLecture(lecture)
        let displayTitle = try store.loadCourseGroups()[courseID]?.title ?? courseID
        // The new lecture's id, and the course's, ride on their own lines
        // (Prompts.hiddenIDs).
        return "Created lecture \(resolvedNumber)\(lecture.title.map { " '\($0)'" } ?? "") in course '\(displayTitle)'.\ncourse_id: \(courseID)\nlecture_id: \(lecture.id)"
    }

    /// A textbook reading as get_course lists it: the sections, the chapter
    /// and its pages, the ids a follow-up call needs, and why.
    static func textbookReadingLine(item: CourseLectureItem, chapter: StudioArticle, unit: SourceUnit?) -> String {
        let pages = unit.flatMap { $0.kind == TextbookReading.unitKind ? TextbookReading.pages(fromLocator: $0.locator) : nil }
        let sections = unit?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var line = "  - Reading: \(sections.isEmpty ? chapter.title : sections)"
        if let pages {
            line += " — \(chapter.title), "
            line += pages.count == 1
                ? "page \(pages.lowerBound) of the chapter"
                : "pages \(pages.lowerBound)–\(pages.upperBound) of the chapter"
        } else if !sections.isEmpty {
            line += " — \(chapter.title)"
        } else {
            line += " (the whole chapter)"
        }
        line += " (item_id: \(item.id), role: reading, source_id: \(chapter.id))"
        if let reason = item.label?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            line += ". Why: \(reason)"
        }
        return line
    }

    static func normalizedCourseLookupValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func courseCandidateLabel(courseID: String, metadata: CourseMetadata) -> String {
        let title = metadata.title ?? courseID
        var qualifiers = ["id: \(courseID)"]
        if let courseCode = nilIfBlank(metadata.courseCode ?? "") {
            qualifiers.append("course_code: \(courseCode)")
        }
        if let institution = nilIfBlank(metadata.institution ?? "") {
            qualifiers.append("institution: \(institution)")
        }
        return "\(title) (\(qualifiers.joined(separator: ", ")))"
    }
}
