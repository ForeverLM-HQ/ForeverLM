import Foundation

/// A textbook read along with a course, over MCP
/// (docs/textbook-readings-design.md): the same `TextbookReadingService`
/// the Mac's Add Textbook sheet runs.
extension MCPDataStore {

    // MARK: save_course_textbook_readings

    /// Saves readings an external assistant selected itself. Unlike
    /// `add_textbook_to_course`, this path makes no model call: the assistant
    /// reads the chapters, authors the placements, and ForeverLM only checks
    /// their identities and page bounds before writing them.
    func saveCourseTextbookReadings(arguments: [String: Any]) async throws -> String {
        let store = try knowledgeStore()
        let (courseID, bookID, courseTitle, lectures) = try await withStoreGate(.shared) {
            let courseID = try resolveExistingCourseID(
                input: arguments["course_id"] as? String ?? "",
                store: store
            )
            let bookID = try resolveTextbookID(arguments["book"] as? String ?? "", store: store)
            let lectures = try store.loadCourseLectures()
                .filter { $0.courseName == courseID }
                .sorted { $0.number < $1.number }
            guard !lectures.isEmpty else {
                throw MCPError.invalidInput("The course has no lectures: \(courseID)")
            }
            return (
                courseID,
                bookID,
                try store.loadCourseGroups()[courseID]?.title ?? courseID,
                lectures
            )
        }

        let outline: TextbookOutline
        do {
            outline = try await TextbookOutlineReader.outline(bookID: bookID, storage: notebookFileStorage)
        } catch {
            throw MCPError.invalidInput("Could not read the textbook outline: \(error.localizedDescription)")
        }
        guard !outline.chapters.isEmpty else {
            throw MCPError.invalidInput("The book has no available chapters: \(outline.title)")
        }
        let placements = try Self.authoredTextbookReadingPlacements(
            arguments["readings"],
            outline: outline,
            lectures: lectures
        )
        try Task.checkCancellation()
        let items = try await notebookFileStorage.replaceTextbookReadings(
            courseID: courseID,
            bookID: bookID,
            placements: placements
        )
        let result = TextbookReadingResult(
            courseID: courseID,
            bookID: bookID,
            bookTitle: outline.title,
            summary: nil,
            placements: placements,
            items: items,
            lecturesWithoutMaterial: []
        )
        return try await withStoreGate(.shared) {
            Self.textbookReadingReport(result, courseTitle: courseTitle, store: store)
        }
    }

    /// Turns the explicit MCP payload into the same checked storage shape the
    /// planner uses. Identity remains deterministic code: every lecture must
    /// belong to the course, every chapter to the named book, and page ranges
    /// must fit the chapter ForeverLM can actually open.
    static func authoredTextbookReadingPlacements(
        _ rawValue: Any?,
        outline: TextbookOutline,
        lectures: [CourseSession]
    ) throws -> [TextbookReadingPlacement] {
        guard let rows = rawValue as? [Any], !rows.isEmpty else {
            throw MCPError.invalidInput("readings must contain at least one reading.")
        }
        let lectureByID = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chapterByID = Dictionary(outline.chapters.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        var byLecture: [String: [TextbookReadingPlacement]] = [:]
        var seen: [String: Set<String>] = [:]

        for (offset, value) in rows.enumerated() {
            let number = offset + 1
            guard let raw = value as? [String: Any] else {
                throw MCPError.invalidInput("Reading \(number) must be an object.")
            }
            let lectureID = (raw["lecture_id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let lecture = lectureByID[lectureID] else {
                throw MCPError.invalidInput("Reading \(number) names a lecture outside this course: \(lectureID).")
            }
            let chapterID = (raw["chapter_source_id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let chapter = chapterByID[chapterID] else {
                throw MCPError.invalidInput("Reading \(number) names a source that is not an available chapter of \(outline.title): \(chapterID).")
            }

            let first = try authoredReadingPage(raw["first_page"], field: "first_page", reading: number)
            let last = try authoredReadingPage(raw["last_page"], field: "last_page", reading: number)
            guard (first == nil) == (last == nil) else {
                throw MCPError.invalidInput("Reading \(number) must give both first_page and last_page, or omit both for the whole chapter.")
            }
            let pages: ClosedRange<Int>?
            if let first, let last {
                guard last >= first else {
                    throw MCPError.invalidInput("Reading \(number) has last_page before first_page.")
                }
                guard let pageCount = chapter.pageCount else {
                    throw MCPError.invalidInput("Reading \(number) gives pages for a chapter without page addresses; omit both page fields to assign the whole chapter.")
                }
                guard last <= pageCount else {
                    throw MCPError.invalidInput("Reading \(number) ends on page \(last), but \(chapter.title) has \(pageCount) pages.")
                }
                pages = first...last
            } else {
                pages = nil
            }

            let suppliedTitle = TextbookOutline.collapsed(raw["title"] as? String ?? "")
            if suppliedTitle.count > 500 {
                throw MCPError.invalidInput("Reading \(number)'s title can be at most 500 characters.")
            }
            let title: String
            if !suppliedTitle.isEmpty {
                title = suppliedTitle
            } else if pages == nil {
                title = chapter.title
            } else {
                throw MCPError.invalidInput("Reading \(number) needs title when it assigns a page range.")
            }
            let reason = TextbookOutline.collapsed(raw["reason"] as? String ?? "")
            guard reason.count <= TextbookReadingPlanning.maximumReasonCharacters else {
                throw MCPError.invalidInput(
                    "Reading \(number)'s reason can be at most \(TextbookReadingPlanning.maximumReasonCharacters) characters."
                )
            }

            let identity = "\(chapterID)|\(pages.map(TextbookReading.locator) ?? "whole")"
            guard seen[lectureID, default: []].insert(identity).inserted else {
                throw MCPError.invalidInput("Reading \(number) duplicates the same chapter pages in this lecture.")
            }
            guard byLecture[lectureID, default: []].count < TextbookReadingPlanning.maximumReadingsPerLecture else {
                throw MCPError.invalidInput(
                    "Lecture \(lecture.number) has more than \(TextbookReadingPlanning.maximumReadingsPerLecture) textbook readings."
                )
            }
            byLecture[lectureID, default: []].append(TextbookReadingPlacement(
                lectureID: lectureID,
                lectureNumber: lecture.number,
                chapterSourceID: chapterID,
                chapterNumber: chapter.number,
                chapterTitle: chapter.title,
                pages: pages,
                title: title,
                reason: reason
            ))
        }
        return lectures.flatMap { byLecture[$0.id] ?? [] }
    }

    private static func authoredReadingPage(_ raw: Any?, field: String, reading: Int) throws -> Int? {
        guard let raw else { return nil }
        guard !(raw is Bool), let number = raw as? NSNumber else {
            throw MCPError.invalidInput("Reading \(reading)'s \(field) must be a positive integer.")
        }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 1,
              value <= Double(Int.max),
              value.rounded(.towardZero) == value else {
            throw MCPError.invalidInput("Reading \(reading)'s \(field) must be a positive integer.")
        }
        return Int(value)
    }

    // MARK: add_textbook_to_course

    /// The minute of planning holds no store gate
    /// (`MCPToolRegistry.selfGatedToolNames`): the course and book are resolved,
    /// and the report read, in shared stretches, and the planner reads and the
    /// readings are saved through the storage actor.
    func addTextbookToCourse(arguments: [String: Any]) async throws -> String {
        let store = try knowledgeStore()
        let (courseID, bookID) = try await withStoreGate(.shared) {
            (
                try resolveExistingCourseID(input: arguments["course_id"] as? String ?? "", store: store),
                try resolveTextbookID(arguments["book"] as? String ?? "", store: store)
            )
        }

        // What the assistant passes is the learner's own words, kept as theirs.
        if let background = arguments["learner_background"] as? String,
           !background.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard LearnerProfile.setAboutYou(background) else {
                throw MCPError.invalidInput(
                    "learner_background can be at most \(LearnerProfile.maximumAboutYouLength) characters."
                )
            }
        }
        if let focus = arguments["course_focus"] as? String,
           !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard LearnerProfile.setCourseFocus(focus, courseID: courseID) else {
                throw MCPError.invalidInput(
                    "course_focus can be at most \(LearnerProfile.maximumFocusLength) characters."
                )
            }
        }
        await PreferenceStore.flushPendingWrites()

        let context = try await CourseLearnerContext.current(courseID: courseID, storage: notebookFileStorage)

        let storage = notebookFileStorage
        let result: TextbookReadingResult
        do {
            let planner = try TextbookReadingService.livePlanner(aiService: AIService())
            let service = TextbookReadingService(
                storage: storage,
                readOutline: { bookID in try await TextbookOutlineReader.outline(bookID: bookID, storage: storage) },
                plan: planner
            )
            let activity = MCPToolActivityReporter.current
            result = try await service.run(courseID: courseID, bookID: bookID, context: context) { stage in
                activity?.reportNow(stage.label)
            }
        } catch let error as TextbookReadingError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try await withStoreGate(.shared) {
            Self.textbookReadingReport(result, courseTitle: try store.loadCourseGroups()[courseID]?.title ?? courseID, store: store)
        }
    }

    static func textbookReadingReport(
        _ result: TextbookReadingResult,
        courseTitle: String,
        store: KnowledgeStore
    ) -> String {
        let lectures = ((try? store.loadCourseLectures()) ?? [])
            .filter { $0.courseName == result.courseID }
            .sorted { $0.number < $1.number }
        // The service returns the saved items in placement order.
        var itemIDByPlacement: [String: String] = [:]
        for (placement, item) in zip(result.placements, result.items) {
            itemIDByPlacement[Self.placementKey(placement)] = item.id
        }
        var lines = ["Readings from \(result.bookTitle) in '\(courseTitle)', chosen for the learner:"]
        if let summary = result.summary { lines.append(summary) }
        lines.append("")
        let byLecture = Dictionary(grouping: result.placements, by: \.lectureID)
        var without: [Int] = []
        for lecture in lectures {
            guard let placements = byLecture[lecture.id], !placements.isEmpty else {
                without.append(lecture.number)
                continue
            }
            lines.append("- Lecture \(lecture.number). \(lecture.title ?? "Lecture \(lecture.number)") (lecture_id: \(lecture.id)):")
            for placement in placements {
                var line = "  - \(placement.title) — \(placement.chapterTitle)"
                if let pages = placement.pages {
                    line += pages.count == 1
                        ? ", page \(pages.lowerBound) of the chapter"
                        : ", pages \(pages.lowerBound)–\(pages.upperBound) of the chapter"
                } else {
                    line += ", the whole chapter"
                }
                if let itemID = itemIDByPlacement[Self.placementKey(placement)] {
                    line += " (item_id: \(itemID), source_id: \(placement.chapterSourceID))"
                } else {
                    line += " (source_id: \(placement.chapterSourceID))"
                }
                if !placement.reason.isEmpty { line += ". Why: \(placement.reason)" }
                lines.append(line)
            }
        }
        if !without.isEmpty {
            lines.append("")
            lines.append("No reading for lecture\(without.count == 1 ? "" : "s") \(without.map(String.init).joined(separator: ", ")).")
        }
        if !result.lecturesWithoutMaterial.isEmpty {
            lines.append("Planned from the title alone, no transcript or notes stored: lecture\(result.lecturesWithoutMaterial.count == 1 ? "" : "s") \(result.lecturesWithoutMaterial.map(String.init).joined(separator: ", ")). fetch_video_transcript those videos and call this again for a closer fit.")
        }
        lines.append("")
        lines.append("Pages count within the chapter, as its [page N] markers in get_source_content do; cite one as [Title](foreverlm://source/SOURCE_ID?page=N). Remove a reading with remove_course_lecture_item. Calling again with the same book replaces its readings.")
        return lines.joined(separator: "\n")
    }

    private static func placementKey(_ placement: TextbookReadingPlacement) -> String {
        "\(placement.lectureID)|\(placement.chapterSourceID)|\(placement.pages.map(TextbookReading.locator) ?? "whole")"
    }

    /// A book from a title, a book id, or one of its chapters' source ids.
    /// Titles are display metadata, so a title two books share is refused
    /// with both ids rather than guessed.
    func resolveTextbookID(_ input: String, store: KnowledgeStore) throws -> String {
        let identifier = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw MCPError.invalidInput("book is required: a book's title, its book id, or a chapter's source_id.")
        }
        let bookIDs = try store.bookGroupIDs()
        if bookIDs.contains(identifier) { return identifier }
        if let viaChapter = try store.bookGroupID(ofChapter: identifier) { return viaChapter }

        let titles = try store.loadBooks().titles
        func title(_ id: String) -> String { titles[id] ?? id }
        let wanted = Self.normalizedCourseLookupValue(identifier)
        let exact = bookIDs.filter { Self.normalizedCourseLookupValue(title($0)) == wanted }
        let matches = exact.isEmpty
            ? bookIDs.filter { Self.normalizedCourseLookupValue(title($0)).contains(wanted) }
            : exact
        if matches.count == 1, let only = matches.first { return only }
        if matches.count > 1 {
            let candidates = matches.sorted().map { "\(title($0)) (book: \($0))" }.joined(separator: "; ")
            throw MCPError.invalidInput("More than one book matches '\(identifier)': \(candidates). Pass the book id.")
        }
        let known = bookIDs.map(title).sorted().prefix(30).joined(separator: "; ")
        throw MCPError.invalidInput("No book in the library matches '\(identifier)'. Books: \(known).")
    }
}

extension KnowledgeStore {
    /// Every book with an active chapter.
    func bookGroupIDs() throws -> Set<String> {
        var ids: Set<String> = []
        try query("""
            SELECT DISTINCT gm.group_id
            FROM group_members gm
            JOIN source_projection sp ON sp.id = gm.source_id
            WHERE sp.source_type = 'book' AND sp.status = 'active'
        """) { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    /// The book a chapter belongs to, or nil when the id is not a chapter.
    func bookGroupID(ofChapter sourceID: String) throws -> String? {
        var groupID: String?
        try queryBind("""
            SELECT gm.group_id
            FROM group_members gm
            JOIN source_projection sp ON sp.id = gm.source_id
            WHERE gm.source_id = ? AND sp.source_type = 'book'
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            groupID = self.string(stmt, 0)
        }
        return groupID
    }
}
