// MCPToolRegistry: runs the course, explainer and walkthrough tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the course, explainer and walkthrough tools; nil for any other name.
    func executeCoursesAndWalkthroughsTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
        case "create_course":
            return try store.createCourse(
                title: arguments["title"] as? String ?? "",
                courseCode: arguments["course_code"] as? String,
                institution: arguments["institution"] as? String,
                instructors: arguments["instructors"] as? String,
                notebookID: arguments["notebook_id"] as? String
            )
        case "generate_course":
            return try await store.generateCourse(
                topic: arguments["topic"] as? String ?? "",
                learnerNotes: arguments["learner_notes"] as? String,
                useWeb: arguments["use_web"] as? Bool ?? false,
                moduleCount: arguments["module_count"] as? Int,
                scheduleStart: arguments["schedule_start"] as? String,
                daysPerModule: arguments["days_per_module"] as? Int,
                writeQuizzes: arguments["quizzes"] as? Bool ?? false,
                chosenSourceIDs: arguments["source_ids"] as? [String] ?? [],
                agreedPlan: arguments["plan"] as? String,
                notebookID: arguments["notebook_id"] as? String
            )
        case "generate_course_quizzes":
            return try await store.generateCourseQuizzes(arguments: arguments)
        case "add_course_quiz_pictures":
            return try await store.addCourseQuizPictures(arguments: arguments)
        case "get_course_quiz":
            return try store.getCourseQuiz(arguments: arguments)
        case "save_course_quiz":
            return try store.saveCourseQuiz(arguments: arguments)
        case "delete_course_quiz":
            return try store.deleteCourseQuiz(arguments: arguments)
        case "rename_course_quiz":
            return try store.renameCourseQuiz(arguments: arguments)
        case "set_course_quiz_picture":
            return try store.setCourseQuizPicture(arguments: arguments)
        case "record_course_quiz_result":
            return try await store.recordCourseQuizResult(arguments: arguments)
        case "save_course_textbook_readings":
            return try await store.saveCourseTextbookReadings(arguments: arguments)
        case "add_textbook_to_course":
            return try await store.addTextbookToCourse(arguments: arguments)
        case "generate_explainer":
            return try await store.generateExplainer(
                sourceID: arguments["source_id"] as? String ?? "",
                lengthName: arguments["length"] as? String,
                generateAudio: arguments["generate_audio"] as? Bool ?? true,
                confirmCost: arguments["confirm_cost"] as? Bool ?? false,
                approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                    ?? MCPRunningWork.defaultSpendLimitUSD
            )
        case "generate_audio_overview":
            return try await store.generateAudioOverview(arguments: arguments)
        case "generate_report":
            return try await store.generateReport(arguments: arguments)
        case "generate_explainer_video":
            return try await store.generateExplainerVideo(arguments: arguments)
        case "generate_walkthrough":
            return try await store.generateWalkthrough(arguments: arguments)
        case "get_walkthrough":
            return try await store.getWalkthrough(arguments: arguments)
        case "list_walkthroughs":
            return try await store.listWalkthroughs(notebookID: arguments["notebook_id"] as? String)
        case "save_walkthrough":
            return try await store.saveWalkthrough(arguments: arguments)
        case "delete_walkthrough":
            return try await store.deleteWalkthrough(arguments: arguments)
        case "update_course":
            return try store.updateCourse(
                courseID: arguments["course_id"] as? String ?? "",
                title: arguments["title"] as? String,
                courseCode: arguments["course_code"] as? String,
                institution: arguments["institution"] as? String,
                instructors: arguments["instructors"] as? String,
                playlistURL: arguments["playlist_url"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                unlinkNotebookID: arguments["unlink_notebook_id"] as? String
            )
        case "delete_course":
            return try store.deleteCourse(courseID: arguments["course_id"] as? String ?? "")
        case "create_course_lecture":
            return try store.createCourseLectureResolved(
                courseIdentifier: arguments["course_id"] as? String
                    ?? arguments["course_name"] as? String
                    ?? "",
                identifierIsStableID: arguments["course_id"] as? String != nil,
                title: arguments["title"] as? String,
                number: arguments["number"] as? Int
            )
        case "rename_course_lecture":
            return try store.renameCourseLecture(
                lectureID: arguments["lecture_id"] as? String ?? "",
                title: arguments["title"] as? String ?? ""
            )
        case "add_source_to_lecture":
            return try store.addSourceToLecture(
                lectureID: arguments["lecture_id"] as? String ?? "",
                sourceID: arguments["source_id"] as? String ?? "",
                role: arguments["role"] as? String
            )
        case "add_paper_to_lecture":
            return try store.addPaperToLecture(
                lectureID: arguments["lecture_id"] as? String ?? "",
                sourceID: arguments["source_id"] as? String ?? "",
                assignedReading: arguments["assigned_reading"] as? Bool
            )
        case "find_lecture_papers":
            return try await store.findLecturePapers(
                lectureID: arguments["lecture_id"] as? String ?? "",
                force: arguments["force"] as? Bool ?? false
            )
        case "ingest_lecture_papers":
            return try await store.ingestLecturePapers(
                lectureID: arguments["lecture_id"] as? String ?? "",
                citedPaperIDs: arguments["cited_paper_ids"] as? [String] ?? [],
                assignedReadingIDs: arguments["assigned_reading_ids"] as? [String] ?? []
            )
        case "remove_course_lecture_item":
            return try store.removeCourseLectureItem(itemID: arguments["item_id"] as? String ?? "")
        default:
            return nil
        }
    }
}
