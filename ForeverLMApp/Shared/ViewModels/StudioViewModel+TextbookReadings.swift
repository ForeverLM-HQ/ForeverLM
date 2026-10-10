import Foundation

/// A textbook's readings in a course (docs/textbook-readings-design.md): the
/// parts of a library book this learner reads with each lecture, planned by
/// the Textbook Readings task from the lectures, the book's own sections and
/// what the learner says about themselves. The Add Textbook sheet and the
/// `add_textbook_to_course` MCP tool run the same `TextbookReadingService`.
extension StudioViewModel {

    /// A reading a lecture holds, resolved for the sidebar.
    struct CourseTextbookReading: Identifiable, Equatable {
        let item: CourseLectureItem
        let chapter: StudioArticle
        let unit: SourceUnit?

        var id: String { item.id }
        /// One-based pages within the chapter; nil reads it whole.
        var pages: ClosedRange<Int>? {
            unit.flatMap { $0.kind == TextbookReading.unitKind ? TextbookReading.pages(fromLocator: $0.locator) : nil }
        }
        /// The sections the pages hold, or the chapter when it is read whole.
        var title: String {
            let sections = unit?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return sections.isEmpty ? chapter.title : sections
        }
        /// Why this learner reads it here, as the plan said; nil when it gave none.
        var reason: String? {
            let text = item.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        /// The first section's heading, for the reader to find on the page.
        var openingHeading: String? {
            guard pages != nil else { return nil }
            return title.components(separatedBy: " · ").first
        }
    }

    /// A lecture item is a textbook reading when it reads a book chapter.
    func isTextbookReading(_ item: CourseLectureItem) -> Bool {
        guard item.role == .reading, let article = article(for: item) else { return false }
        return article.sourceType == .book
    }

    /// The textbook readings a lecture holds, in the order it lists them.
    func textbookReadings(for lectureID: String) -> [CourseTextbookReading] {
        courseLectureItems(for: lectureID).compactMap { item in
            guard item.role == .reading,
                  let chapter = article(for: item),
                  chapter.sourceType == .book else { return nil }
            return CourseTextbookReading(
                item: item,
                chapter: chapter,
                unit: item.sourceUnitId.flatMap { courseSourceUnitsByID[$0] }
            )
        }
    }

    /// Read when the chapter is marked read, or its saved page has reached the
    /// reading's last page.
    func isTextbookReadingFinished(_ reading: CourseTextbookReading) -> Bool {
        let chapter = articleWithCurrentReadingProgress(reading.chapter)
        if chapter.isRead { return true }
        guard let pages = reading.pages, let page = chapter.readingPositionPage else { return false }
        return page + 1 >= pages.upperBound
    }

    /// The row's tooltip: the book and where in it, then why.
    func textbookReadingHelp(_ reading: CourseTextbookReading) -> String {
        var place = reading.chapter.title
        if let pages = reading.pages {
            place += pages.count == 1
                ? ", page \(pages.lowerBound) of the chapter"
                : ", pages \(pages.lowerBound)–\(pages.upperBound) of the chapter"
        }
        var lines = [[reading.chapter.parentGroup.map(bookDisplayName), place].compactMap { $0 }.joined(separator: " — ")]
        if let reason = reading.reason { lines.append(reason) }
        return lines.joined(separator: "\n")
    }

    /// The books a course reads from, by book ID.
    func textbookIDs(inCourse courseID: String) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for lecture in courseLectures(for: courseID) {
            for reading in textbookReadings(for: lecture.id) {
                guard let bookID = reading.chapter.parentGroup, seen.insert(bookID).inserted else { continue }
                ids.append(bookID)
            }
        }
        return ids
    }

    /// Reloads the page units after the outline changed. Cheap — one small
    /// table — and only asked for when some item names a unit, so a library
    /// without readings never runs it.
    func refreshCourseSourceUnits(for items: [CourseLectureItem]) {
        guard items.contains(where: { $0.sourceUnitId != nil }) else {
            if !courseSourceUnitsByID.isEmpty { courseSourceUnitsByID = [:] }
            return
        }
        courseSourceUnitsRefreshTask?.cancel()
        courseSourceUnitsRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let units = try await storage.loadCourseSourceUnits()
                guard !Task.isCancelled else { return }
                if units != courseSourceUnitsByID {
                    courseSourceUnitsByID = units
                    invalidateCourseDerivedState()
                }
            } catch {
                logger.error("Failed to load course source units: \(error.localizedDescription)")
            }
        }
    }

    /// Plans `bookID` into `courseID` for this learner. Saves what they wrote
    /// about themselves first — `aboutYou` for every course, `focus` for this
    /// one — except in Screen record mode, where a take's words are not the
    /// learner's. Throws what failed; the course is untouched then.
    @discardableResult
    func addTextbookReadings(
        courseID: String,
        bookID: String,
        aboutYou: String,
        focus: String
    ) async throws -> TextbookReadingResult {
        guard textbookReadingStages[courseID] == nil else { throw TextbookReadingError.alreadyRunning }
        // The model is resolved before anything else, so a run never starts
        // on a route that cannot finish it.
        let planner = try TextbookReadingService.livePlanner(aiService: aiService)
        textbookReadingStages[courseID] = .fetchingTranscripts
        defer { textbookReadingStages[courseID] = nil }

        if !ScreenRecordMode.isEffective {
            guard LearnerProfile.setAboutYou(aboutYou) else {
                throw TextbookReadingError.tooLong("About you", limit: LearnerProfile.maximumAboutYouLength)
            }
            guard LearnerProfile.setCourseFocus(focus, courseID: courseID) else {
                throw TextbookReadingError.tooLong("What you need from the course", limit: LearnerProfile.maximumFocusLength)
            }
        }
        let context = CourseLearnerContext(
            aboutYou: aboutYou,
            focus: focus,
            notebooks: try await storage.learnerContextNotebooks(courseID: courseID)
        )

        // A lecture whose transcript was never fetched gets it first, so the
        // planner reads what the lecture says rather than only its title.
        for lecture in courseLectures(for: courseID) {
            for item in courseLectureItems(for: lecture.id) where item.role == .video {
                guard let video = article(for: item) else { continue }
                _ = await lectureQuizContent(for: video)
            }
        }

        let storage = self.storage
        let service = TextbookReadingService(
            storage: storage,
            readOutline: { bookID in try await TextbookOutlineReader.outline(bookID: bookID, storage: storage) },
            plan: planner
        )
        let result = try await service.run(courseID: courseID, bookID: bookID, context: context) { [weak self] stage in
            self?.textbookReadingStages[courseID] = stage
        }
        await refreshCourseOutline()
        return result
    }

    /// The toast after a plan: how many readings, and in how many lectures.
    static func textbookReadingSummary(_ result: TextbookReadingResult, courseTitle: String) -> String {
        let readings = result.placements.count
        let lectures = Set(result.placements.map(\.lectureID)).count
        return "\(courseTitle): \(readings) reading\(readings == 1 ? "" : "s") from \(result.bookTitle) across \(lectures) lecture\(lectures == 1 ? "" : "s")."
    }

    /// Opens a reading in the Reader: the chapter, at its first page, with the
    /// opening section's heading marked when the page carries it.
    func openTextbookReading(_ reading: CourseTextbookReading, in windowState: StudioWindowState) {
        let chapterID = reading.chapter.id
        windowState.sidebarSelectedSourceIDs = [chapterID]
        readerPoppedOut = false
        Task {
            await selectArticle(chapterID, in: windowState, revealingReader: true)
            if let pages = reading.pages {
                requestReaderPassage(reading.openingHeading, page: pages.lowerBound, for: chapterID)
            }
        }
    }
}
