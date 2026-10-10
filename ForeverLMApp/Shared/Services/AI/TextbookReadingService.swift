import Foundation

enum TextbookReadingError: LocalizedError, Equatable {
    case courseNotFound(String)
    case courseHasNoLectures(String)
    case bookNotFound(String)
    case bookHasNoChapters(String)
    /// The Textbook Readings model is not usable; the message says why.
    case notConfigured(String)
    /// The plan placed nothing. Earlier readings from the book stay.
    case nothingToRead(book: String)
    /// A textbook is already being planned into this course.
    case alreadyRunning
    /// What the learner wrote about themselves is longer than it may be.
    case tooLong(String, limit: Int)

    var errorDescription: String? {
        switch self {
        case .courseNotFound(let id):
            return "No course \(id) in the library."
        case .courseHasNoLectures(let title):
            return "\(title) has no lectures to read along with."
        case .bookNotFound(let id):
            return "No book \(id) in the library."
        case .bookHasNoChapters(let title):
            return "\(title) has no chapters here to read."
        case .notConfigured(let message):
            return message
        case .nothingToRead(let book):
            return "\(book) has nothing this course needs you to read."
        case .alreadyRunning:
            return "A textbook is already being added to this course."
        case .tooLong(let field, let limit):
            return "\(field) can be at most \(limit) characters."
        }
    }
}

/// One stage of planning a book into a course, for the sheet's progress line.
enum TextbookReadingStage: Equatable, Sendable {
    /// The app fetches transcripts the course's videos never had, first.
    case fetchingTranscripts
    case readingBook
    case readingLectures
    case choosing
    case saving
    case finished

    var label: String {
        switch self {
        case .fetchingTranscripts: return "Fetching lecture transcripts…"
        case .readingBook: return "Reading the book's contents…"
        case .readingLectures: return "Reading the lectures…"
        case .choosing: return "Choosing your readings…"
        case .saving: return "Adding the readings…"
        case .finished: return "Done"
        }
    }
}

/// Everything the planner is shown.
struct TextbookReadingRequest: Sendable {
    let courseTitle: String
    let instructors: String?
    let lectures: [TextbookLectureBrief]
    let outline: TextbookOutline
    let context: CourseLearnerContext
}

struct TextbookReadingResult: Sendable {
    let courseID: String
    let bookID: String
    let bookTitle: String
    let summary: String?
    let placements: [TextbookReadingPlacement]
    /// The lecture items written, in placement order.
    let items: [CourseLectureItem]
    /// Lecture numbers the planner had only a title for.
    let lecturesWithoutMaterial: [Int]
}

/// Plans a textbook into a course: the parts of the book this learner reads
/// with each lecture, and why. The Mac's Add Textbook sheet and the
/// `add_textbook_to_course` MCP tool run this same service, so a reading is
/// the same whoever asked for it. See docs/textbook-readings-design.md.
///
/// Nothing is written until the plan has been checked: a failure at any stage
/// leaves the course as it was, earlier readings from the book included.
struct TextbookReadingService: Sendable {
    /// Lays the book out for the planner. The Mac reads chapter files' own
    /// sections (`TextbookOutlineReader`); a test hands in a fixture.
    typealias OutlineReader = @Sendable (_ bookID: String) async throws -> TextbookOutline
    /// Asks the model. The shipped one is `livePlanner`; a test hands in a
    /// canned draft.
    typealias Planner = @Sendable (_ request: TextbookReadingRequest) async throws -> TextbookReadingDraft

    let storage: StorageService
    let readOutline: OutlineReader
    let plan: Planner

    /// Lecture items whose text says what a lecture covers. A reading, an
    /// exercise or a reference is what the lecture sends the learner to, not
    /// what it teaches.
    static let lectureMaterialRoles: Set<CourseLectureItemRole> = [.video, .notes, .slides]

    /// The Textbook Readings model from Settings. Resolved before any work,
    /// so a run never starts on a model that cannot finish it.
    static func livePlanner(aiService: AIService) throws -> Planner {
        let task = AITask.courseTextbookReadings
        guard let config = KeychainService.resolveConfig(for: task) else {
            throw TextbookReadingError.notConfigured(
                KeychainService.backgroundAIUnavailableMessage(for: task)
                    ?? "\(task.displayName) is not configured."
            )
        }
        return { request in
            try await aiService.planTextbookReadings(request, config: config)
        }
    }

    func run(
        courseID: String,
        bookID: String,
        context: CourseLearnerContext,
        onProgress: @MainActor @Sendable (TextbookReadingStage) -> Void = { _ in }
    ) async throws -> TextbookReadingResult {
        let workflowID = "textbook-readings-\(UUID().uuidString.lowercased())"
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.$activityID.withValue(workflowID) {
                try await runStages(courseID: courseID, bookID: bookID, context: context, onProgress: onProgress)
            }
        }
    }

    private func runStages(
        courseID: String,
        bookID: String,
        context: CourseLearnerContext,
        onProgress: @MainActor @Sendable (TextbookReadingStage) -> Void
    ) async throws -> TextbookReadingResult {
        let metadata = try await storage.loadCourseMetadata()
        let lectures = try await storage.loadCourseLectures()
            .filter { $0.courseName == courseID }
            .sorted { $0.number < $1.number }
        guard metadata[courseID] != nil || !lectures.isEmpty else {
            throw TextbookReadingError.courseNotFound(courseID)
        }
        let courseTitle = metadata[courseID]?.title ?? courseID
        guard !lectures.isEmpty else { throw TextbookReadingError.courseHasNoLectures(courseTitle) }

        await onProgress(.readingBook)
        let outline = try await readOutline(bookID)
        guard !outline.chapters.isEmpty else { throw TextbookReadingError.bookHasNoChapters(outline.title) }
        try Task.checkCancellation()

        await onProgress(.readingLectures)
        let briefs = try await lectureBriefs(lectures: lectures, skipping: outline.chapterSourceIDs)
        try Task.checkCancellation()

        await onProgress(.choosing)
        let draft = try await plan(TextbookReadingRequest(
            courseTitle: courseTitle,
            instructors: metadata[courseID]?.instructors,
            lectures: briefs,
            outline: outline,
            context: context
        ))
        let placements = TextbookReadingPlanning.placements(from: draft, outline: outline, lectures: briefs)
        guard !placements.isEmpty else { throw TextbookReadingError.nothingToRead(book: outline.title) }
        try Task.checkCancellation()

        await onProgress(.saving)
        let items = try await storage.replaceTextbookReadings(
            courseID: courseID,
            bookID: bookID,
            placements: placements
        )
        await onProgress(.finished)
        return TextbookReadingResult(
            courseID: courseID,
            bookID: bookID,
            bookTitle: outline.title,
            summary: draft.summary.map(TextbookOutline.collapsed).flatMap { $0.isEmpty ? nil : $0 },
            placements: placements,
            items: items,
            lecturesWithoutMaterial: briefs.filter { $0.material.isEmpty }.map(\.number)
        )
    }

    /// Each lecture's own material, within the planner's budget: the video's
    /// transcript first, then its notes and slides. Sources the learner keeps
    /// from AI are left out, and so is the book itself.
    private func lectureBriefs(
        lectures: [CourseSession],
        skipping chapterIDs: Set<String>
    ) async throws -> [TextbookLectureBrief] {
        let lectureIDs = Set(lectures.map(\.id))
        let items = try await storage.loadCourseLectureItems().filter { lectureIDs.contains($0.lectureId) }
        let excluded = try await storage.knowledgeBoundaryExcludedSourceIDs()
        let itemsByLecture = Dictionary(grouping: items, by: \.lectureId)
        var textByLecture: [String: String] = [:]
        for lecture in lectures {
            let candidates = (itemsByLecture[lecture.id] ?? [])
                .filter { item in
                    guard let sourceID = item.sourceId,
                          !chapterIDs.contains(sourceID),
                          !excluded.contains(sourceID) else { return false }
                    return Self.lectureMaterialRoles.contains(item.role)
                }
                .sorted { lhs, rhs in
                    (lhs.role == .video ? 0 : 1, lhs.sortIndex) < (rhs.role == .video ? 0 : 1, rhs.sortIndex)
                }
            var texts: [String] = []
            for item in candidates {
                guard let sourceID = item.sourceId,
                      let text = await storage.loadSourceContent(sourceID)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                texts.append(text)
            }
            textByLecture[lecture.id] = texts.joined(separator: "\n\n")
        }
        let budgets = TextbookReadingPlanning.lectureBudgets(lengths: textByLecture.mapValues(\.count))
        return lectures.map { lecture in
            let text = textByLecture[lecture.id] ?? ""
            let budget = budgets[lecture.id] ?? 0
            let title = lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TextbookLectureBrief(
                lectureID: lecture.id,
                number: lecture.number,
                title: (title?.isEmpty == false ? title : nil) ?? "Lecture \(lecture.number)",
                material: TextbookReadingPlanning.lectureMaterial(text, budget: budget),
                wasCut: text.count > budget
            )
        }
    }
}
