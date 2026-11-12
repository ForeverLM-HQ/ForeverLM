import Foundation

// MARK: - Lecture titles from what the lectures teach
//
// The product owner, 2026-09-27, looking at a course page whose lectures read "Course
// organization", "Mitochondrial Cell Biology 1", "… 2", "… 3": "these course
// titles should also be generated based on the content that's in them;
// perhaps not necessarily the same as the youtube video title always; though
// it can be if that title is informative." A playlist import names each
// lecture after its video, which says where a lecture sits in a series rather
// than what it teaches. This reads each lecture's transcript, notes and slides
// and names it for its subject, keeping the video's title where that already
// does the job. See docs/courses-design.md, *Lecture titles*.
//
// Meaning comes from the model; structure stays code (AGENTS.md, "never let
// an LLM decide identity"): a title only ever changes a lecture's display
// name, a lecture keeps the ordinal its stored title led with ("3A) "), a
// lecture with nothing to read is never renamed, and no two lectures end up
// with the same title.

enum CourseLectureNamingError: LocalizedError, Equatable {
    case courseNotFound(String)
    case courseHasNoLectures(String)
    /// The Lecture Titles model is not usable; the message says why.
    case notConfigured(String)
    /// This course's lectures are already being named.
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .courseNotFound(let id):
            return "No course \(id) in the library."
        case .courseHasNoLectures(let title):
            return "\(title) has no lectures to name."
        case .notConfigured(let message):
            return message
        case .alreadyRunning:
            return "This course's lectures are already being named."
        }
    }
}

/// One lecture as the namer sees it.
struct CourseLectureNamingBrief: Equatable, Sendable {
    let lectureID: String
    let number: Int
    /// The lecture's title now, without the ordinal it leads with.
    let currentTitle: String
    /// The titles of the videos, notes and slides filed under it, where they
    /// say something the lecture's own title does not.
    let itemTitles: [String]
    /// Empty when nothing is stored to read; such a lecture keeps its title.
    let material: String
    /// The material was cut to fit the budget.
    let wasCut: Bool
}

/// Everything the namer is shown.
struct CourseLectureNamingRequest: Sendable {
    let courseID: String
    let courseTitle: String
    let instructors: String?
    /// The lectures to name, in lecture order.
    let lectures: [CourseLectureNamingBrief]
    /// The course's other lectures, whose titles stay as they are: shown so
    /// the new titles read as one outline with them.
    let otherTitles: [(number: Int, title: String)]
}

/// The namer's answer, as it arrives. Nothing in it is trusted:
/// `CourseLectureNaming.retitles` keeps only lectures the request offered.
struct CourseLectureNamingDraft: Decodable, Sendable {
    struct Lecture: Decodable, Sendable {
        let lecture: Int?
        let title: String?

        private enum CodingKeys: String, CodingKey { case lecture, title }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .lecture) {
                lecture = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .lecture) {
                lecture = Int(text.trimmingCharacters(in: .whitespaces))
            } else {
                lecture = nil
            }
            title = try? container.decodeIfPresent(String.self, forKey: .title)
        }
    }

    let lectures: [Lecture]

    private enum CodingKeys: String, CodingKey { case lectures }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lectures = (try? container.decodeIfPresent([Lecture].self, forKey: .lectures)) ?? []
    }
}

/// One lecture given a new title.
struct CourseLectureRetitle: Equatable, Sendable {
    let lectureID: String
    let number: Int
    /// The title as the course page showed it before, without its ordinal.
    let previousTitle: String
    /// The title as stored: the new name behind the ordinal the old one led with.
    let storedTitle: String
}

struct CourseLectureNamingResult: Sendable {
    let courseID: String
    let retitled: [CourseLectureRetitle]
    /// Lectures read whose title already said what they teach.
    let kept: Int
    /// Lecture numbers with nothing stored to read.
    let lecturesWithoutMaterial: [Int]
}

enum CourseLectureNaming {
    /// Titles need far less of a lecture than a quiz does: its section
    /// headings and four windows through it say what it covers.
    static let characterBudget = 80_000
    static let minimumLectureCharacters = 2_000
    /// Longer than this is a sentence, not a title; the lecture keeps its own.
    static let maximumTitleLength = 90
    /// Lecture items whose text says what a lecture teaches.
    static let materialRoles: Set<CourseLectureItemRole> = TextbookReadingService.lectureMaterialRoles

    static func maxTokens(lectureCount: Int) -> Int {
        min(4_000, max(600, 200 + lectureCount * 60))
    }

    /// The new titles to store, in lecture order. A proposal is kept only for
    /// a lecture the request offered with something to read, once per
    /// lecture, cleaned of quotes and of a number the model put in front, and
    /// no longer than a title. One that says what the lecture's title already
    /// says is no change. One that repeats another lecture's title, or a title
    /// already given in this batch, is dropped and that lecture keeps its own,
    /// so the course never shows two lectures under one name.
    static func retitles(
        from draft: CourseLectureNamingDraft,
        request: CourseLectureNamingRequest,
        storedTitles: [String: String?]
    ) -> [CourseLectureRetitle] {
        var briefByNumber: [Int: CourseLectureNamingBrief] = [:]
        for brief in request.lectures where briefByNumber[brief.number] == nil {
            briefByNumber[brief.number] = brief
        }
        var proposals: [String: String] = [:]
        for entry in draft.lectures {
            guard let number = entry.lecture,
                  let brief = briefByNumber[number],
                  !brief.material.isEmpty,
                  proposals[brief.lectureID] == nil,
                  let title = cleanedTitle(entry.title) else { continue }
            proposals[brief.lectureID] = title
        }

        var taken = Set(request.otherTitles.map { key($0.title) })
        var result: [CourseLectureRetitle] = []
        let named = request.lectures.sorted { $0.number < $1.number }
        for brief in named {
            guard let proposal = proposals[brief.lectureID],
                  key(proposal) != key(brief.currentTitle) else { continue }
            let othersNow = named.filter { $0.lectureID != brief.lectureID }.map { key($0.currentTitle) }
            guard !taken.contains(key(proposal)), !othersNow.contains(key(proposal)) else { continue }
            taken.insert(key(proposal))
            let stored = storedTitles[brief.lectureID] ?? nil
            result.append(CourseLectureRetitle(
                lectureID: brief.lectureID,
                number: brief.number,
                previousTitle: brief.currentTitle,
                storedTitle: storedTitle(proposal, replacing: stored)
            ))
        }
        return result
    }

    /// A proposal as a title, or nil when there is none to keep.
    static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var title = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        title = title.trimmingCharacters(in: quotes.union(.whitespaces))
        title = StudioViewModel.stripDanglingLectureSeparators(StudioViewModel.strippedLeadingLectureOrdinal(title))
        while title.hasSuffix(".") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count <= maximumTitleLength else { return nil }
        return title
    }

    /// The stored form: the new name behind the ordinal the stored title led
    /// with, so a lecture part ("3A)") and what reads it back
    /// (`StudioViewModel.materialOrdinal`) survive a new name.
    static func storedTitle(_ title: String, replacing stored: String?) -> String {
        guard let stored,
              let range = StudioViewModel.leadingLectureOrdinalRange(in: stored) else { return title }
        let ordinal = String(stored[range]).trimmingCharacters(in: .whitespaces)
        return ordinal.isEmpty ? title : "\(ordinal) \(title)"
    }

    /// A title as the course page shows it: without its ordinal.
    static func displayTitle(_ stored: String?) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return StudioViewModel.stripDanglingLectureSeparators(StudioViewModel.strippedLeadingLectureOrdinal(trimmed))
    }

    /// Two titles are one when they differ only by case, accents and spacing.
    static func key(_ title: String) -> String {
        displayTitle(title)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Names a course's lectures for what each one teaches. The course menu's
/// Retitle Lectures from Content and a playlist import run this same service.
/// Nothing is written until the answer has been checked, and a failure leaves
/// every lecture's title as it was.
struct CourseLectureNamingService: Sendable {
    /// Asks the model. The shipped one is `liveNamer`; a test hands in a
    /// canned draft.
    typealias Namer = @Sendable (_ request: CourseLectureNamingRequest) async throws -> CourseLectureNamingDraft

    let storage: StorageService
    let name: Namer

    /// The Lecture Titles model from Settings. Resolved before any work, so a
    /// run never starts on a model that cannot finish it.
    static func liveNamer(aiService: AIService) throws -> Namer {
        let task = AITask.courseLectureNaming
        guard let config = KeychainService.resolveConfig(for: task) else {
            throw CourseLectureNamingError.notConfigured(
                KeychainService.backgroundAIUnavailableMessage(for: task)
                    ?? "\(task.displayName) is not configured."
            )
        }
        return { request in
            try await aiService.nameCourseLectures(request, config: config)
        }
    }

    /// Names `lectureIDs` (every lecture when nil) of `courseID`. The model
    /// is asked only when at least one of them has something to read.
    func run(courseID: String, lectureIDs: Set<String>? = nil) async throws -> CourseLectureNamingResult {
        try await AIUsageAttribution.withWorkflow("lecture-titles-\(UUID().uuidString.lowercased())") {
            try await runStages(courseID: courseID, lectureIDs: lectureIDs)
        }
    }

    private func runStages(courseID: String, lectureIDs: Set<String>?) async throws -> CourseLectureNamingResult {
        let metadata = try await storage.loadCourseMetadata()
        let lectures = try await storage.loadCourseLectures()
            .filter { $0.courseName == courseID }
            .sorted { $0.number < $1.number }
        guard metadata[courseID] != nil || !lectures.isEmpty else {
            throw CourseLectureNamingError.courseNotFound(courseID)
        }
        let courseTitle = metadata[courseID]?.title ?? courseID
        guard !lectures.isEmpty else { throw CourseLectureNamingError.courseHasNoLectures(courseTitle) }

        let named = lectures.filter { lectureIDs?.contains($0.id) ?? true }
        let others = lectures.filter { !(lectureIDs?.contains($0.id) ?? true) }
        let briefs = try await self.briefs(for: named)
        let withoutMaterial = briefs.filter { $0.material.isEmpty }.map(\.number)
        guard briefs.contains(where: { !$0.material.isEmpty }) else {
            return CourseLectureNamingResult(courseID: courseID, retitled: [], kept: 0, lecturesWithoutMaterial: withoutMaterial)
        }
        try Task.checkCancellation()

        let request = CourseLectureNamingRequest(
            courseID: courseID,
            courseTitle: courseTitle,
            instructors: metadata[courseID]?.instructors,
            lectures: briefs,
            otherTitles: others.map { lecture in
                let title = CourseLectureNaming.displayTitle(lecture.title)
                return (number: lecture.number, title: title.isEmpty ? "Lecture \(lecture.number)" : title)
            }
        )
        let draft = try await name(request)
        try Task.checkCancellation()

        let retitles = CourseLectureNaming.retitles(
            from: draft,
            request: request,
            storedTitles: Dictionary(uniqueKeysWithValues: named.map { ($0.id, $0.title) })
        )
        let lecturesByID = Dictionary(uniqueKeysWithValues: named.map { ($0.id, $0) })
        for retitle in retitles {
            guard var lecture = lecturesByID[retitle.lectureID] else { continue }
            lecture.title = retitle.storedTitle
            try await storage.saveCourseLecture(lecture)
        }
        return CourseLectureNamingResult(
            courseID: courseID,
            retitled: retitles,
            kept: briefs.filter { !$0.material.isEmpty }.count - retitles.count,
            lecturesWithoutMaterial: withoutMaterial
        )
    }

    /// Each lecture's own material within the budget: the video's transcript
    /// first, then its notes and slides. Sources the learner keeps from AI are
    /// left out.
    private func briefs(for lectures: [CourseSession]) async throws -> [CourseLectureNamingBrief] {
        let lectureIDs = Set(lectures.map(\.id))
        let items = try await storage.loadCourseLectureItems().filter { lectureIDs.contains($0.lectureId) }
        let excluded = try await storage.knowledgeBoundaryExcludedSourceIDs()
        let itemsByLecture = Dictionary(grouping: items, by: \.lectureId)
        let sources = Dictionary(
            try await storage.loadPersistedSources(ids: Array(Set(items.compactMap(\.sourceId)))).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var textByLecture: [String: String] = [:]
        var itemTitlesByLecture: [String: [String]] = [:]
        for lecture in lectures {
            let candidates = (itemsByLecture[lecture.id] ?? [])
                .filter { item in
                    guard let sourceID = item.sourceId, !excluded.contains(sourceID) else { return false }
                    return CourseLectureNaming.materialRoles.contains(item.role)
                }
                .sorted { lhs, rhs in
                    (lhs.role == .video ? 0 : 1, lhs.sortIndex) < (rhs.role == .video ? 0 : 1, rhs.sortIndex)
                }
            var texts: [String] = []
            var titles: [String] = []
            let lectureKey = CourseLectureNaming.key(lecture.title ?? "")
            for item in candidates {
                guard let sourceID = item.sourceId else { continue }
                if let source = sources[sourceID] {
                    let title = CourseLectureNaming.displayTitle(source.title)
                    if !title.isEmpty, CourseLectureNaming.key(title) != lectureKey, !titles.contains(title) {
                        titles.append(title)
                    }
                }
                guard let text = await storage.loadSourceContent(sourceID)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                texts.append(text)
            }
            textByLecture[lecture.id] = texts.joined(separator: "\n\n")
            itemTitlesByLecture[lecture.id] = titles
        }
        let budgets = TextbookReadingPlanning.lectureBudgets(
            lengths: textByLecture.mapValues(\.count),
            total: CourseLectureNaming.characterBudget,
            minimum: CourseLectureNaming.minimumLectureCharacters
        )
        return lectures.map { lecture in
            let text = textByLecture[lecture.id] ?? ""
            let budget = budgets[lecture.id] ?? 0
            let title = CourseLectureNaming.displayTitle(lecture.title)
            return CourseLectureNamingBrief(
                lectureID: lecture.id,
                number: lecture.number,
                currentTitle: title.isEmpty ? "Lecture \(lecture.number)" : title,
                itemTitles: itemTitlesByLecture[lecture.id] ?? [],
                material: TextbookReadingPlanning.lectureMaterial(text, budget: budget),
                wasCut: text.count > budget
            )
        }
    }
}

extension AIService {
    /// Asks what each lecture teaches, as a title. The draft is checked by
    /// `CourseLectureNaming.retitles`; this only asks and decodes.
    func nameCourseLectures(
        _ request: CourseLectureNamingRequest,
        config: AITaskConfig
    ) async throws -> CourseLectureNamingDraft {
        let system = AITask.courseLectureNaming.effectivePrompt ?? Prompts.courseLectureNaming
        let response = try await call(
            config: config,
            system: system,
            user: Self.courseLectureNamingUserMessage(request),
            maxTokens: CourseLectureNaming.maxTokens(lectureCount: request.lectures.count),
            temperature: 0.2,
            jsonMode: true,
            sourceTitle: request.courseTitle,
            subjectID: request.courseID,
            subjectType: StudioSourceType.course.rawValue
        )
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// The course, the titles that stay, then each lecture to name with what
    /// it covers.
    static func courseLectureNamingUserMessage(_ request: CourseLectureNamingRequest) -> String {
        var lines: [String] = []
        var course = "Course: \(request.courseTitle)"
        if let instructors = request.instructors?.trimmingCharacters(in: .whitespacesAndNewlines), !instructors.isEmpty {
            course += ", taught by \(instructors)"
        }
        lines.append(course)
        if !request.otherTitles.isEmpty {
            lines.append("")
            lines.append("The course's other lectures, whose titles stay as they are:")
            for other in request.otherTitles.sorted(by: { $0.number < $1.number }) {
                lines.append("Lecture \(other.number): \(other.title)")
            }
        }
        lines.append("")
        lines.append("Lectures to name (\(request.lectures.count)):")
        for lecture in request.lectures {
            lines.append("")
            lines.append("=== Lecture \(lecture.number) · current title: \(lecture.currentTitle) ===")
            if !lecture.itemTitles.isEmpty {
                lines.append("Filed under it: " + lecture.itemTitles.joined(separator: "; "))
            }
            if lecture.material.isEmpty {
                lines.append("[Nothing is stored to read for this lecture; keep its current title.]")
            } else {
                lines.append(lecture.material)
                if lecture.wasCut {
                    lines.append("[Sampled: the lecture is longer than shown.]")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
