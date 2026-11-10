import Foundation

// MARK: - Request

/// What the learner asked for. Everything the pipeline decides on its own —
/// which sources, how many modules when unspecified, the course title — comes
/// back in the blueprint, never in here.
struct CourseGenerationRequest: Equatable, Sendable {
    /// The subject, as typed. Also the seed for library search and web research.
    let topic: String
    /// What the learner already knows or wants out of it. Optional; shapes the
    /// level and the emphasis of the plan.
    let learnerNotes: String
    /// Where the learner is coming from, in their own words: the account's
    /// About you (`LearnerProfile`), which every course is tailored to.
    /// Empty when they have not written one.
    let learnerBackground: String
    /// Whether the pipeline may run a web investigation and import what it cites.
    let usesWeb: Bool
    /// A preferred module count, or nil to let the planner size the course from
    /// the material.
    let moduleCount: Int?
    /// When set, one module is placed every `daysPerModule` days from this
    /// date, by a Goal nested in the notebook that follows the course — the
    /// one it was asked from, or, with none given, a notebook made for it.
    let scheduleStart: Date?
    let daysPerModule: Int
    /// The notebook the course is made from and that follows it
    /// (docs/courses-design.md, "A course is its own thing"): it follows the
    /// course from its first save, gaining its sources. The course itself
    /// lives in no notebook. Nil: no notebook follows it, unless a schedule
    /// makes one named after it to hold the Goal.
    let followingNotebookID: String?
    /// Library sources the learner settled on while planning the course in
    /// chat. They head the planner's list, marked as chosen, and the planner
    /// is told to build on them; the library search still adds what they
    /// miss.
    let chosenSourceIDs: [String]
    /// The plan the learner and the chat agreed on — modules, their order,
    /// emphasis, what to leave out — in the chat's own words. Empty when the
    /// course was asked for without a planning conversation.
    let agreedPlan: String

    static let moduleCountRange = 2...12
    static let daysPerModuleRange = 1...14

    init(
        topic: String,
        learnerNotes: String = "",
        learnerBackground: String = "",
        usesWeb: Bool = false,
        moduleCount: Int? = nil,
        scheduleStart: Date? = nil,
        daysPerModule: Int = 2,
        chosenSourceIDs: [String] = [],
        agreedPlan: String = "",
        followingNotebookID: String? = nil
    ) {
        self.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.learnerNotes = learnerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.learnerBackground = learnerBackground.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usesWeb = usesWeb
        self.moduleCount = moduleCount.map { min(max($0, Self.moduleCountRange.lowerBound), Self.moduleCountRange.upperBound) }
        self.scheduleStart = scheduleStart
        self.daysPerModule = min(max(daysPerModule, Self.daysPerModuleRange.lowerBound), Self.daysPerModuleRange.upperBound)
        var seen: Set<String> = []
        self.chosenSourceIDs = chosenSourceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.agreedPlan = agreedPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        let following = followingNotebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.followingNotebookID = following?.isEmpty == false ? following : nil
    }
}

// MARK: - Source briefs

/// What the planner and the writer are told about one library source.
///
/// The excerpt and ideas are enough to decide what a source is good for; the
/// writer is later given the full text of the sources its module names.
struct CourseSourceBrief: Identifiable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: StudioSourceType
    let author: String?
    let wordCount: Int?
    /// The opening of the source's text, bounded.
    let excerpt: String
    /// Extracted ideas, when the source has been consumed and extracted.
    let ideas: [String]
    /// Where the pipeline found it: the library, or a web page it imported.
    let origin: Origin

    enum Origin: String, Equatable, Sendable {
        case library
        case web
        /// Named by the learner while planning the course in chat.
        case chosen
    }

    var id: String { sourceID }

    static let excerptCharacterLimit = 1_200

    static func excerpt(from content: String?) -> String {
        guard let content else { return "" }
        let collapsed = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > excerptCharacterLimit else { return collapsed }
        return String(collapsed.prefix(excerptCharacterLimit)) + "…"
    }
}

// MARK: - Blueprint

/// The planner's output: one curriculum over the sources it was shown.
///
/// The model chooses order, grouping and emphasis. It never chooses identity:
/// `validated(against:)` drops every source id the pipeline did not offer, so a
/// hallucinated id can never reach `course_lecture_items`.
struct CourseBlueprint: Codable, Equatable, Sendable {
    struct Module: Codable, Equatable, Sendable {
        let title: String
        /// What the learner should be able to do after the module, one line each.
        let objectives: [String]
        /// Library sources the module draws on, in reading order.
        let sourceIDs: [String]
        /// What the exercises should push on, as a note to the writer.
        let exerciseFocus: String

        enum CodingKeys: String, CodingKey {
            case title
            case objectives
            case sourceIDs = "source_ids"
            case exerciseFocus = "exercise_focus"
        }

        init(title: String, objectives: [String], sourceIDs: [String], exerciseFocus: String) {
            self.title = title
            self.objectives = objectives
            self.sourceIDs = sourceIDs
            self.exerciseFocus = exerciseFocus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            objectives = try container.decodeIfPresent([String].self, forKey: .objectives) ?? []
            sourceIDs = try container.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
            exerciseFocus = try container.decodeIfPresent(String.self, forKey: .exerciseFocus) ?? ""
        }
    }

    let title: String
    /// Two or three sentences on what the course covers and where it ends.
    let summary: String
    /// Who the course is pitched at, given the learner's notes.
    let audience: String
    let modules: [Module]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case audience
        case modules
    }

    init(title: String, summary: String, audience: String, modules: [Module]) {
        self.title = title
        self.summary = summary
        self.audience = audience
        self.modules = modules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        audience = try container.decodeIfPresent(String.self, forKey: .audience) ?? ""
        modules = try container.decodeIfPresent([Module].self, forKey: .modules) ?? []
    }

    /// Keeps only source ids the pipeline offered, deduplicated within a module,
    /// and drops modules without a title. A module that loses every source stays:
    /// the writer can still teach it from the research notes and its objectives.
    func validated(against offeredSourceIDs: Set<String>) -> CourseBlueprint {
        let cleanedModules: [Module] = modules.compactMap { module in
            let title = module.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            var seen: Set<String> = []
            let sourceIDs = module.sourceIDs.filter { id in
                offeredSourceIDs.contains(id) && seen.insert(id).inserted
            }
            return Module(
                title: title,
                objectives: module.objectives
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                sourceIDs: sourceIDs,
                exerciseFocus: module.exerciseFocus.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return CourseBlueprint(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            audience: audience.trimmingCharacters(in: .whitespacesAndNewlines),
            modules: cleanedModules
        )
    }

    var referencedSourceIDs: [String] {
        var seen: Set<String> = []
        return modules.flatMap(\.sourceIDs).filter { seen.insert($0).inserted }
    }
}

// MARK: - Lesson drafts

/// The writer's output for one module.
///
/// Both texts are plain prose with line headings, not Markdown: the course
/// reader shows text verbatim (see docs/course-generation-design.md).
struct CourseLessonDraft: Codable, Equatable, Sendable {
    let lesson: String
    let exercises: String

    enum CodingKeys: String, CodingKey {
        case lesson
        case exercises
    }

    var isUsable: Bool {
        !lesson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !exercises.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Generated lesson sources

/// The URL grammar and titles of the sources a generated course writes.
///
/// URLs are `foreverlm://course/<courseID>/lesson/<n>` and
/// `foreverlm://course/<courseID>/exercises/<n>`. `SourceIdentity.stableID`
/// derives a source id from its URL, so the same course id and module number
/// always name the same source and a re-save is an update rather than a
/// duplicate.
enum GeneratedCourseLesson {
    enum Kind: String, CaseIterable, Sendable {
        case lesson
        case exercises

        var titlePrefix: String {
            switch self {
            case .lesson: return "Lesson"
            case .exercises: return "Exercises"
            }
        }
    }

    static let scheme = "foreverlm"
    static let host = "course"

    static func url(courseID: String, module number: Int, kind: Kind) -> String {
        "\(scheme)://\(host)/\(courseID)/\(kind.rawValue)/\(number)"
    }

    static func title(module number: Int, moduleTitle: String, kind: Kind) -> String {
        "\(kind.titlePrefix) \(number): \(moduleTitle)"
    }

    /// Whether a source URL names a generated lesson or exercise sheet.
    static func isGeneratedLessonURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host else { return false }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 3, Kind(rawValue: String(segments[1])) != nil else { return false }
        return Int(segments[2]) != nil
    }

    /// The lecture-item role a library source takes in a module, from what it is.
    static func readingRole(for sourceType: StudioSourceType) -> CourseLectureItemRole {
        switch sourceType {
        case .video: return .video
        case .podcast: return .podcast
        case .article, .xPost, .manual, .unclassified: return .article
        case .paper, .book, .course: return .reading
        case .meeting: return .reference
        }
    }

    /// Study days for a course of `moduleCount` modules: the first on `start`,
    /// then one every `daysPerModule` days, each at the start of its day.
    static func plannedDays(start: Date, moduleCount: Int, daysPerModule: Int, calendar: Calendar = .current) -> [Date] {
        guard moduleCount > 0 else { return [] }
        let firstDay = calendar.startOfDay(for: start)
        let stride = max(1, daysPerModule)
        return (0..<moduleCount).map { index in
            calendar.date(byAdding: .day, value: index * stride, to: firstDay) ?? firstDay
        }
    }
}

// MARK: - Progress and result

struct CourseGenerationProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case gathering
        case researching
        case importing(done: Int, total: Int)
        case planning
        case writing(module: Int, total: Int)
        case saving
        case scheduling
        case finished

        var label: String {
            switch self {
            case .gathering: return "Searching the library"
            case .researching: return "Researching the web"
            case .importing(let done, let total): return "Importing sources \(done)/\(total)"
            case .planning: return "Planning the curriculum"
            case .writing(let module, let total): return "Writing module \(module) of \(total)"
            case .saving: return "Saving the course"
            case .scheduling: return "Placing modules on the calendar"
            case .finished: return "Done"
            }
        }
    }

    let stage: Stage
    /// Stages completed so far, for a determinate bar.
    let completedSteps: Int
    let totalSteps: Int
}

struct CourseGenerationResult: Equatable, Sendable {
    let courseID: String
    let blueprint: CourseBlueprint
    let lectures: [CourseSession]
    /// Lesson and exercise source ids per module, in module order.
    let lessonSourceIDs: [String]
    let exerciseSourceIDs: [String]
    /// Library sources the course attached, including web imports.
    let attachedSourceIDs: [String]
    /// The notebook that follows the course: the one it was asked from, or the
    /// one a schedule made for it. Nil when none does; the course itself lives
    /// in no notebook.
    let notebookID: String?
    /// With a schedule: the Goal nested in that notebook that carries the
    /// deadline and the day placements.
    let goalID: String?
    /// Whether the notebook was made for the course (a schedule with no
    /// notebook given), rather than the one it was asked from.
    var madeNotebookForCourse: Bool = false
}

enum CourseGenerationError: LocalizedError, Equatable {
    case emptyTopic
    case noModelConfigured(AITask)
    case nothingToTeach
    case emptyPlan
    case emptyLesson(module: String)

    var errorDescription: String? {
        switch self {
        case .emptyTopic:
            return "Enter a topic for the course."
        case .noModelConfigured(let task):
            return "\(task.displayName) has no available AI model, or nothing to pay for it. Check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
        case .nothingToTeach:
            return "Nothing in the library matches this topic. Add sources first, or allow web research."
        case .emptyPlan:
            return "The planner returned no modules."
        case .emptyLesson(let module):
            return "The writer returned an empty lesson for “\(module)”."
        }
    }
}
