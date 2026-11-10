import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

// A course as the phone's course page lists it: the Mac's path
// (`StudioViewModel.coursePath`, docs/courses-design.md) over the synced
// outline, with the same gate (`CourseGate`). Platform-neutral, so the Mac
// unit tests compile it beside `MobileCloudSourceModels.swift`.

/// One row of a course's path: a lecture video, a reading or material filed
/// under the lecture, or a quiz.
struct MobileCoursePathRow: Identifiable, Equatable, Sendable, CourseGateStep {
    enum Kind: Equatable, Sendable {
        case video(MobileCloudSource)
        /// A paper assigned as reading, a textbook chapter, or the notes,
        /// slides or problem set filed under the lecture; `role` is the Mac's
        /// `CourseLectureItemRole` raw value.
        case material(MobileCloudSource, role: String)
        case quiz(CourseQuiz)
    }

    /// The Mac's entry id: `video-<item>`, `material-<item>` or `quiz-<quiz>`.
    let id: String
    let kind: Kind
    /// "3) Isolated Mitochondria" for a lecture's video, the source's own
    /// title, "Quiz", or the topics a quiz covers.
    let title: String
    /// For a quiz: its lecture, the lectures it covers, or the course.
    var quizSubtitle: String? = nil

    var gatingQuizID: String? { quiz?.id }

    var quiz: CourseQuiz? {
        if case .quiz(let quiz) = kind { return quiz }
        return nil
    }

    var source: MobileCloudSource? {
        switch kind {
        case .video(let source), .material(let source, _): return source
        case .quiz: return nil
        }
    }

    /// The synced row that holds this quiz's latest sitting.
    var scoreKeys: [String] {
        guard let quiz else { return [] }
        return [LectureQuizScore.preferenceKey(courseQuizID: quiz.id)]
    }
}

/// A lecture and the rows under it, drawn as one section.
struct MobileCourseUnit: Identifiable, Equatable, Sendable {
    let lecture: MobileCourseLecture
    /// The lecture's title without its number, or "Lecture N".
    let title: String
    let rows: [MobileCoursePathRow]
    var id: String { lecture.id }
}

/// The page's blocks in order: a unit per lecture, with checkpoints and the
/// course test between and after them.
enum MobileCoursePathBlock: Identifiable, Equatable, Sendable {
    case unit(MobileCourseUnit)
    case milestone(MobileCoursePathRow)

    var id: String {
        switch self {
        case .unit(let unit): return "unit-\(unit.id)"
        case .milestone(let row): return row.id
        }
    }
}

struct MobileCoursePath: Equatable, Sendable {
    let course: MobileCloudCourse
    let blocks: [MobileCoursePathBlock]
    /// Course material no lecture claims, closing the page as further
    /// reading. Not on the path, so the gate never holds it back.
    let furtherMaterial: [MobileCloudSource]

    /// Every row in path order: each unit's rows, then the milestone after it.
    var rows: [MobileCoursePathRow] {
        blocks.flatMap { block -> [MobileCoursePathRow] in
            switch block {
            case .unit(let unit): return unit.rows
            case .milestone(let row): return [row]
            }
        }
    }

    var quizRows: [MobileCoursePathRow] { rows.filter { $0.quiz != nil } }

    /// The course's path, in the Mac's order: each lecture's videos, then its
    /// readings (papers assigned as reading, then textbook chapters), then
    /// its notes, slides and problem sets, then its practice quiz once
    /// written; a checkpoint or the course test after the lecture it follows,
    /// and quizzes whose lectures are gone at the end. A paper a lecture's
    /// video only cites is not on the path, and a quiz with no questions has
    /// nothing to take, so it has no row. Items whose source has not synced
    /// to this phone are left out rather than faked.
    static func build(course: MobileCloudCourse, sources: [MobileCloudSource]) -> MobileCoursePath {
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lectures = course.lectures.sorted(by: MobileSourceGrouping.lectureOrder)
        let itemsByLecture = Dictionary(grouping: course.lectureItems, by: \.lectureID)
        let placements = CourseQuizPlanning.placements(
            quizzes: course.quizzes.filter { !$0.questions.isEmpty },
            lectureOrder: lectures.map(\.id)
        )
        let numberByLecture = Dictionary(lectures.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        var blocks: [MobileCoursePathBlock] = []

        func quizRow(_ quiz: CourseQuiz, lectureTitle: String?) -> MobileCoursePathRow {
            let numbers = quiz.lectureIDs.compactMap { numberByLecture[$0] }.sorted()
            let subtitle: String
            switch quiz.kind {
            case .practice:
                subtitle = lectureTitle
                    ?? (quiz.title.hasPrefix("Quiz: ") ? String(quiz.title.dropFirst(6)) : quiz.title)
            case .checkpoint:
                if let first = numbers.first, let last = numbers.last {
                    subtitle = first == last ? "Lecture \(first)" : "Lectures \(first)–\(last)"
                } else {
                    subtitle = course.title
                }
            case .test:
                subtitle = course.title
            }
            return MobileCoursePathRow(
                id: "quiz-\(quiz.id)",
                kind: .quiz(quiz),
                title: quiz.kind == .practice && !quiz.hasTopicTitle ? "Quiz" : quiz.title,
                quizSubtitle: subtitle
            )
        }

        var claimed = Set<String>()
        for lecture in lectures {
            let items = (itemsByLecture[lecture.id] ?? []).sorted(by: MobileSourceGrouping.lectureItemOrder)
            claimed.formUnion(items.map(\.sourceID))
            let citedOnly = MobileSourceGrouping.citedOnlyItemIDs(items, sourcesByID: sourcesByID)
            var videos: [(item: MobileCourseLectureItem, source: MobileCloudSource)] = []
            var papers: [(item: MobileCourseLectureItem, source: MobileCloudSource)] = []
            var chapters: [(item: MobileCourseLectureItem, source: MobileCloudSource)] = []
            var materials: [(item: MobileCourseLectureItem, source: MobileCloudSource)] = []
            for item in items where !citedOnly.contains(item.id) {
                guard let source = sourcesByID[item.sourceID] else { continue }
                // Paper identity is the source type, not the item's role, as
                // on the Mac: older associations use `reading`, and a paper
                // stays a paper when it was attached as `reference`.
                if source.sourceType == "paper" {
                    papers.append((item, source))
                } else if item.role == "video" {
                    videos.append((item, source))
                } else if item.role == "reading", source.sourceType == "book" {
                    chapters.append((item, source))
                } else {
                    materials.append((item, source))
                }
            }

            let ownTitle = lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lectureTitle = ownTitle.isEmpty ? videos.first?.source.title : ownTitle
            let unitTitle = strippedLeadingOrdinal(lectureTitle ?? "")
            var rows: [MobileCoursePathRow] = []
            for (item, source) in videos {
                // One video under the lecture's heading reads as the lecture;
                // a lecture split across videos keeps each video's own title.
                let title = videos.count == 1
                    ? MobileSourceGrouping.lectureDisplayTitle(number: lecture.number, title: lectureTitle)
                    : source.title
                rows.append(MobileCoursePathRow(id: "video-\(item.id)", kind: .video(source), title: title))
            }
            for (item, source) in papers + chapters + materials {
                rows.append(MobileCoursePathRow(
                    id: "material-\(item.id)",
                    kind: .material(source, role: item.role),
                    title: source.title
                ))
            }

            let placed = placements.afterLecture[lecture.id] ?? []
            let practiceID = CourseQuizPlanning.practiceID(courseID: course.id, lectureID: lecture.id)
            if let practice = placed.first(where: { $0.id == practiceID }) {
                rows.append(quizRow(
                    practice,
                    lectureTitle: lectureTitle ?? "Lecture \(lecture.number)"
                ))
            }
            blocks.append(.unit(MobileCourseUnit(
                lecture: lecture,
                title: unitTitle.isEmpty ? "Lecture \(lecture.number)" : unitTitle,
                rows: rows
            )))
            for quiz in placed where quiz.id != practiceID {
                blocks.append(.milestone(quizRow(quiz, lectureTitle: nil)))
            }
        }
        for quiz in placements.atEnd {
            blocks.append(.milestone(quizRow(quiz, lectureTitle: nil)))
        }

        let further = sources
            .filter { $0.parentGroup == course.id && !claimed.contains($0.id) }
            .sorted(by: MobileSourceGrouping.memberOrder)
        return MobileCoursePath(course: course, blocks: blocks, furtherMaterial: further)
    }

    /// "5) Isolated Mitochondria" reads "Isolated Mitochondria" under a
    /// section headed Lecture 5: the Mac's `strippedLeadingLectureOrdinal`,
    /// with the same two prefixes (`CourseTitleParserCache`).
    static func strippedLeadingOrdinal(_ title: String) -> String {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for regex in leadingOrdinalPrefixes {
            guard let match = regex.firstMatch(in: title, range: range),
                  match.range.location == 0,
                  let matched = Range(match.range, in: title) else { continue }
            return String(title[matched.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let leadingOrdinalPrefixes: [NSRegularExpression] = [
        #"^\s*\d{1,3}(?:[a-z]|\.\d{1,3})?\)\s*"#,
        #"^\s*(?:lecture|lec|chapter|chap|ch|session|week|class|unit|section)s?\s*[_#.:\-–—]*\s*\d{1,3}(?:[a-z]|\.\d{1,3})?\s*(?:[\)_#.:\-–—]\s*|\s)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
}

/// Where the learner stands on a course: which rows are done, the gate over
/// them, and what each quiz row says about its sitting.
struct MobileCourseProgress: Equatable, Sendable {
    /// Latest sittings by synced key (`MobileCoursePathRow.scoreKeys`).
    var scores: [String: LectureQuizScore]
    /// Sources a finished review covered.
    var reviewedSourceIDs: Set<String>

    func score(for row: MobileCoursePathRow) -> LectureQuizScore? {
        row.scoreKeys.lazy.compactMap { scores[$0] }.first
    }

    /// Watched to the end, marked read, or reviewed; for a quiz, completed.
    func isFinished(_ row: MobileCoursePathRow) -> Bool {
        if row.quiz != nil { return score(for: row) != nil }
        guard let source = row.source else { return false }
        return source.isWatched || source.readAt != nil || reviewedSourceIDs.contains(source.id)
    }

    /// Whether the row can be done at all: a video watched, a textbook
    /// chapter read, a quiz completed, a paper or web article marked read. A
    /// course PDF or lesson sheet can only be reviewed, so until it is it has
    /// nothing for Continue to wait on (`CourseGate.untrackedEntryIDs`).
    static func hasDoneState(_ row: MobileCoursePathRow) -> Bool {
        switch row.kind {
        case .video, .quiz:
            return true
        case .material(let source, let role):
            if source.sourceType == "video" { return true }
            if role == "reading", source.sourceType == "book" { return true }
            return ForeverLMCore.supportsReadTracking(
                sourceType: source.sourceType,
                url: source.url,
                hasLocalFile: source.localFilePath != nil,
                isArchivedArticle: source.isArchivedArticle
            )
        }
    }

    func gate(for path: MobileCoursePath) -> CourseGate {
        CourseGate(entries: path.rows, isFinished: isFinished, hasDoneState: Self.hasDoneState)
    }

    /// The quiz row's second line: what kind of quiz a named one is, what it
    /// covers, and whether it has been passed or how many it got right.
    func quizDetail(for row: MobileCoursePathRow) -> String? {
        guard let quiz = row.quiz else { return nil }
        var parts: [String] = []
        if quiz.hasTopicTitle, quiz.kind != .test {
            parts.append(quiz.kind == .practice ? "Quiz" : "Checkpoint")
        }
        if quiz.kind != .practice, let subtitle = row.quizSubtitle { parts.append(subtitle) }
        if let score = score(for: row), score.matches(questionCount: quiz.questions.count) {
            if score.passes {
                parts.append("Passed · \(score.label)")
            } else if score.hasPassed {
                parts.append("Passed earlier · \(score.label)")
            } else {
                parts.append(score.label)
            }
        } else {
            // A quiz rewritten since its last sitting reads like a new one.
            let count = quiz.questions.count
            parts.append(count == 1 ? "1 question" : "\(count) questions")
        }
        return parts.joined(separator: " · ")
    }

    /// The name a quiz goes by when a locked row waits on it.
    static func quizName(_ row: MobileCoursePathRow) -> String {
        guard let quiz = row.quiz else { return row.title }
        switch quiz.kind {
        case .practice:
            return quiz.hasTopicTitle ? "the quiz \(quiz.title)" : "the quiz on \(row.quizSubtitle ?? "this lecture")"
        case .checkpoint:
            return quiz.hasTopicTitle ? "the checkpoint \(quiz.title)" : "\(quiz.title) (\(row.quizSubtitle ?? ""))"
        case .test:
            return "the course test"
        }
    }
}

/// What the grader reads of the lecture for one question. The Mac numbers a
/// lecture's transcript the way its reader parses it and sends the stretch a
/// question's lines name; the phone does not parse transcripts that way, so
/// it finds the question's own quote in the lecture's text and sends the
/// passage around it. A question with no quote, or one the text no longer
/// holds, sends the quote alone, or nothing, and says so: the reference
/// answer and key points are still there to grade against.
enum MobileCourseQuizStretch {
    /// Characters kept on each side of the quote.
    static let radius = 1_500

    static func text(for question: CourseQuizQuestion, in content: String?) -> String {
        let quote = question.quote.map(collapsedWhitespace) ?? ""
        guard !quote.isEmpty else {
            return "(Not available on this device: grade against the reference answer and key points.)"
        }
        guard let content else { return quote }
        let text = collapsedWhitespace(content)
        guard let found = text.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return quote
        }
        let start = text.index(found.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(found.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var stretch = text[start..<end]
        // Whole words at both ends.
        if start != text.startIndex, let space = stretch.firstIndex(of: " ") {
            stretch = stretch[stretch.index(after: space)...]
        }
        if end != text.endIndex, let space = stretch.lastIndex(of: " ") {
            stretch = stretch[..<space]
        }
        return String(stretch)
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

// MARK: - Home's Courses

/// A course's progress as its card on the Mac's Courses tab says it
/// (`CourseProgress`): the lecture videos finished, or every item filed
/// under a lecture when the course has no video; finished is watched to the
/// end, marked read, or reviewed.
struct MobileCourseCardProgress: Equatable, Sendable {
    let finished: Int
    let total: Int
    let countsLectureVideos: Bool

    init(path: MobileCoursePath, reviewedSourceIDs: Set<String>) {
        let progress = MobileCourseProgress(scores: [:], reviewedSourceIDs: reviewedSourceIDs)
        let items = path.rows.filter { $0.source != nil }
        let videos = items.filter { if case .video = $0.kind { return true }; return false }
        let counted = videos.isEmpty ? items : videos
        finished = counted.filter(progress.isFinished).count
        total = counted.count
        countsLectureVideos = !videos.isEmpty
    }

    var isComplete: Bool { total > 0 && finished == total }

    var fractionFinished: Double {
        total > 0 ? Double(finished) / Double(total) : 0
    }

    /// "3 of 12 lectures finished", "All 12 lectures finished", "Finished",
    /// in the Mac's words.
    var summary: String {
        let noun = countsLectureVideos
            ? (total == 1 ? "lecture" : "lectures")
            : (total == 1 ? "item" : "items")
        if isComplete {
            return total == 1 ? "Finished" : "All \(total) \(noun) finished"
        }
        return "\(finished) of \(total) \(noun) finished"
    }
}

/// Home's Courses (docs/notebooks-design.md, "Courses beside notebooks on
/// screen"): every course in the library that is not hidden, not only those
/// a notebook follows, since a course lives in no notebook (2026-10-03). Each
/// with its progress and the notebooks that follow it, by title, as the
/// Mac's Courses tab lists them.
enum MobileCoursesHome {
    struct Row: Identifiable, Equatable, Sendable {
        let course: MobileCloudCourse
        let progress: MobileCourseCardProgress
        /// The notebooks that follow the course (`linkedCourseIDs`), in Home's
        /// order of `notebooks`.
        let notebooks: [MobileCloudNotebook]

        var id: String { course.id }

        /// "Linked to Mitochondria, Ageing"; nil when no notebook follows it.
        var notebooksLine: String? {
            notebooks.isEmpty ? nil : "Linked to " + notebooks.map { NotebookTitle($0.title).text }.joined(separator: ", ")
        }
    }

    static func rows(
        courses: [MobileCloudCourse],
        sources: [MobileCloudSource],
        reviewedSourceIDs: Set<String>,
        notebooks: [MobileCloudNotebook]
    ) -> [Row] {
        courses
            .filter { !$0.isHidden }
            .sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            .map { course in
                Row(
                    course: course,
                    progress: MobileCourseCardProgress(
                        path: MobileCoursePath.build(course: course, sources: sources),
                        reviewedSourceIDs: reviewedSourceIDs
                    ),
                    notebooks: notebooks.filter { $0.linkedCourseIDs.contains(course.id) }
                )
            }
    }
}
