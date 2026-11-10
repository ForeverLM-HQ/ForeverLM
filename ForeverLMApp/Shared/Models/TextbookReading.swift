import CryptoKit
import Foundation

// MARK: - The learner a course is tailored to

/// The learner context an AI step may use to tailor a course: where the
/// learner is coming from and what they need. The product owner, 2026-09-26: "the course
/// should always be tailored to my needs and where I'm coming from". The
/// design record is docs/textbook-readings-design.md.
///
/// Every layer is the learner's own words or the learner's own records:
/// - `aboutYou`, the account's standing description of their background
///   (asked by Add Textbook; `account.about_you` over MCP), written once and read by every course;
/// - `focus`, what they want from this one course;
/// - the Notebooks the course is linked to, whose instructions, research
///   questions and Goals say what the course is for.
///
/// Nothing here is inferred by a model, and nothing is filled in when the
/// learner has not said it: an empty context leaves the course itself as the
/// writer's context rather than becoming a guess about the learner.
struct CourseLearnerContext: Equatable, Sendable {
    struct Notebook: Equatable, Sendable {
        let title: String
        /// The Notebook's standing instructions (`LearningGoalRecord.description`).
        let instructions: String?
        let researchQuestions: [String]
        /// Titles of the open Goals tagged to the Notebook, with their deadlines.
        let goals: [String]
    }

    var aboutYou: String
    var focus: String
    var notebooks: [Notebook]

    init(aboutYou: String = "", focus: String = "", notebooks: [Notebook] = []) {
        self.aboutYou = aboutYou.trimmingCharacters(in: .whitespacesAndNewlines)
        self.focus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notebooks = notebooks
    }

    var isEmpty: Bool { aboutYou.isEmpty && focus.isEmpty && notebooks.isEmpty }

    /// Instructions longer than this are cut: a Notebook's standing
    /// instructions can run to pages, and the writer needs their gist, not a
    /// second copy of the Notebook's brief.
    static let maximumInstructionCharacters = 1_200
    static let maximumNotebooks = 3

    /// The block a writer's prompt carries, or nil when there is nothing to
    /// tailor to.
    var promptBlock: String? {
        guard !isEmpty else { return nil }
        var lines = ["The learner:"]
        if !aboutYou.isEmpty {
            lines.append("- Where they are coming from, in their words: \(Self.oneLine(aboutYou))")
        }
        if !focus.isEmpty {
            lines.append("- What they need from this course, in their words: \(Self.oneLine(focus))")
        }
        for notebook in notebooks.prefix(Self.maximumNotebooks) {
            var line = "- This course serves their Notebook \"\(notebook.title)\"."
            if let instructions = notebook.instructions.map(Self.oneLine), !instructions.isEmpty {
                let cut = instructions.count > Self.maximumInstructionCharacters
                    ? String(instructions.prefix(Self.maximumInstructionCharacters)) + "…"
                    : instructions
                line += " Its instructions: \(cut)"
            }
            if !notebook.researchQuestions.isEmpty {
                line += " Its questions: " + notebook.researchQuestions.prefix(5).map(Self.oneLine).joined(separator: "; ") + "."
            }
            if !notebook.goals.isEmpty {
                line += " Its Goals: " + notebook.goals.prefix(5).map(Self.oneLine).joined(separator: "; ") + "."
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension CourseLearnerContext {
    /// The learner as they have described themselves, for one course: their
    /// About you, what they said they need from it, and the Notebooks it serves.
    static func current(courseID: String, storage: StorageService) async throws -> CourseLearnerContext {
        CourseLearnerContext(
            aboutYou: LearnerProfile.aboutYou,
            focus: LearnerProfile.courseFocus(courseID: courseID),
            notebooks: try await storage.learnerContextNotebooks(courseID: courseID)
        )
    }
}

/// The learner's own words about themselves, kept as synced preferences.
///
/// Both are per-member state: they follow the account to every Mac, and they
/// never enter a course record, so a team's copy of a course never carries
/// one member's background (teams-design.md).
enum LearnerProfile {
    /// Synced: the learner's background, the same on every Mac and for every
    /// course. Asked by Add Textbook; `account.about_you` over MCP.
    static let aboutYouPreferenceKey = "account.aboutYou"
    /// Synced, one row per course (`course.focus.<courseID>`), so focusing two
    /// courses on two Macs never collides.
    static let courseFocusPreferenceKeyPrefix = "course.focus."

    static let maximumAboutYouLength = 4_000
    static let maximumFocusLength = 1_000

    static var aboutYou: String {
        (UserDefaults.standard.string(forKey: aboutYouPreferenceKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Under generation 2 the focus is the member's Enrollment (schema v2 §3.5.12,
    /// `CourseEnrollmentStore`); generation 1 keeps the row.
    static func courseFocus(courseID: String) -> String {
        return CourseEnrollmentStore.focus(courseID: courseID)
    }

    /// Saves the background, or clears it when blank. False, and nothing
    /// saved, when it is longer than `maximumAboutYouLength`.
    @discardableResult
    static func setAboutYou(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maximumAboutYouLength else { return false }
        guard text != aboutYou else { return true }
        if text.isEmpty {
            PreferenceStore.remove(forKey: aboutYouPreferenceKey)
        } else {
            PreferenceStore.set(text, forKey: aboutYouPreferenceKey)
        }
        return true
    }

    /// Saves what the learner wants from one course, or clears it when blank.
    /// False, and nothing saved, when it is longer than `maximumFocusLength`.
    @discardableResult
    static func setCourseFocus(_ raw: String, courseID: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maximumFocusLength else { return false }
        guard text != courseFocus(courseID: courseID) else { return true }
        CourseEnrollmentStore.setFocus(text, courseID: courseID)
        return true
    }
}

// MARK: - The book, as the planner reads it

/// A textbook laid out for the reading planner: its chapters in reading order,
/// each with the sections its own pages carry and what the learner has done
/// with it.
///
/// Sections come from the chapter file's bookmarks, or from its headings read
/// off the page (`BookSectionIndex`), never from a model: the planner picks
/// among handles this outline mints, and a handle it did not mint is dropped.
struct TextbookOutline: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        /// `c<chapter>s<section>`: the planner's name for it within one plan.
        let handle: String
        /// As the book prints it.
        let title: String
        /// One-based pages within the chapter, counted the way the chapter's
        /// `[page N]` markers and the reader count them. The last page is the
        /// one the next section opens on, which the section usually ends on.
        let pages: ClosedRange<Int>
        /// The section's opening words, so the planner can judge its level.
        let excerpt: String
    }

    struct Chapter: Equatable, Sendable {
        enum Progress: String, Equatable, Sendable {
            case unread
            case started
            case read
            case reviewed
        }

        /// `c<number>`.
        let handle: String
        /// One-based, in reading order.
        let number: Int
        let sourceID: String
        let title: String
        /// Nil for a chapter without pages (an EPUB or text chapter).
        let pageCount: Int?
        /// Empty when the chapter carries no sections of its own; it is then
        /// read whole.
        let sections: [Section]
        /// The chapter's opening words, for a chapter without sections.
        let excerpt: String
        let progress: Progress
    }

    let bookID: String
    let title: String
    let author: String?
    let edition: String?
    let chapters: [Chapter]

    var chapterSourceIDs: Set<String> { Set(chapters.map(\.sourceID)) }

    // MARK: Building

    static func chapterHandle(_ number: Int) -> String { "c\(number)" }
    static func sectionHandle(chapter: Int, section: Int) -> String { "c\(chapter)s\(section)" }

    /// The sections of one chapter from its outline: `entries` are the
    /// section titles with the zero-based page each opens on, as
    /// `BookSectionIndex` reads them; `pageCount` is the chapter's page count;
    /// `text` is the chapter's stored text with its `[page N]` markers, for
    /// the excerpts. An entry on a page the chapter does not have is dropped,
    /// and a chapter with fewer than two sections left has none: one section
    /// is the chapter.
    static func sections(
        chapterNumber: Int,
        entries: [(title: String, pageIndex: Int)],
        pageCount: Int,
        text: String?
    ) -> [Section] {
        guard pageCount > 0 else { return [] }
        let inside = entries
            .map { (title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), pageIndex: $0.pageIndex) }
            .filter { !$0.title.isEmpty && $0.pageIndex >= 0 && $0.pageIndex < pageCount }
            .sorted { $0.pageIndex < $1.pageIndex }
        guard inside.count >= 2 else { return [] }
        let pages = text.map(pageTexts) ?? [:]
        var sections: [Section] = []
        for (index, entry) in inside.enumerated() {
            let first = entry.pageIndex + 1
            let last = index + 1 < inside.count ? max(first, inside[index + 1].pageIndex + 1) : pageCount
            sections.append(Section(
                handle: sectionHandle(chapter: chapterNumber, section: index + 1),
                title: entry.title,
                pages: first...last,
                excerpt: excerpt(from: pages, title: entry.title, pages: first...last)
            ))
        }
        return sections
    }

    /// Characters of opening text shown per section, and per chapter read
    /// whole.
    static let sectionExcerptCharacters = 320
    static let chapterExcerptCharacters = 600

    /// The text of each one-based page, split at the `[page N]` lines the
    /// PDF text extractor writes. Text before the first marker is dropped: it
    /// is the chapter's title block, which the outline already names. A
    /// chapter's stored text keeps its page breaks as form feeds and carries
    /// no markers, so it is labelled first (`PDFPageMarkers.labeled`), the
    /// way the text handed to a model is.
    static func pageTexts(_ text: String) -> [Int: String] {
        let text = PDFPageMarkers.labeled(text)
        var pages: [Int: String] = [:]
        var current: Int?
        var buffer: [Substring] = []
        func flush() {
            if let current { pages[current] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            buffer = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let number = pageMarker(line) {
                flush()
                current = number
            } else if current != nil {
                buffer.append(line)
            }
        }
        flush()
        return pages
    }

    /// The page number of a `[page N]` marker line, or nil.
    static func pageMarker(_ line: Substring) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[page "), trimmed.hasSuffix("]") else { return nil }
        return Int(trimmed.dropFirst(6).dropLast())
    }

    /// The count of `[page N]` markers: a chapter's page count when its file
    /// is not at hand to count.
    static func pageCount(ofText text: String) -> Int? {
        let count = pageTexts(text).count
        return count > 0 ? count : nil
    }

    /// The section's opening words: from its title where the title is found
    /// on its first page, else from the top of that page.
    private static func excerpt(from pages: [Int: String], title: String, pages range: ClosedRange<Int>) -> String {
        guard let firstPage = pages[range.lowerBound] else { return "" }
        let page = collapsed(firstPage)
        let start = page.range(of: collapsed(title), options: [.caseInsensitive, .diacriticInsensitive])
            .map { page[$0.upperBound...] } ?? Substring(page)
        return clipped(String(start), to: sectionExcerptCharacters)
    }

    /// The opening of a chapter read whole.
    static func chapterExcerpt(_ text: String?) -> String {
        guard let text else { return "" }
        let pages = pageTexts(text)
        let body = pages.isEmpty
            ? text
            : pages.keys.sorted().prefix(2).compactMap { pages[$0] }.joined(separator: " ")
        return clipped(collapsed(body), to: chapterExcerptCharacters)
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - The lectures, as the planner reads them

/// One lecture of the course: what it is called and what it covers, from its
/// own material (the video's transcript, its notes or its lesson).
struct TextbookLectureBrief: Equatable, Sendable {
    let lectureID: String
    let number: Int
    let title: String
    /// Empty when the lecture has no text stored yet; the planner then has its
    /// title to go on and is told so.
    let material: String
    /// The material was cut to fit the planner's budget.
    let wasCut: Bool
}

// MARK: - The plan

/// The planner's answer, as it arrives. Nothing in it is trusted:
/// `TextbookReadingPlanning.placements` keeps only lectures and handles the
/// request offered.
struct TextbookReadingDraft: Decodable, Sendable {
    struct Lecture: Decodable, Sendable {
        let lecture: Int?
        let readings: [Reading]

        private enum CodingKeys: String, CodingKey { case lecture, readings }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decodeIfPresent(Int.self, forKey: .lecture) {
                lecture = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .lecture) {
                lecture = Int(text.trimmingCharacters(in: .whitespaces))
            } else {
                lecture = nil
            }
            readings = (try? container.decodeIfPresent([Reading].self, forKey: .readings)) ?? []
        }
    }

    struct Reading: Decodable, Sendable {
        let parts: [String]
        let why: String

        private enum CodingKeys: String, CodingKey { case parts, why }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let list = try? container.decodeIfPresent([String].self, forKey: .parts) {
                parts = list
            } else if let single = try? container.decodeIfPresent(String.self, forKey: .parts) {
                parts = [single]
            } else {
                parts = []
            }
            why = (try? container.decodeIfPresent(String.self, forKey: .why)) ?? ""
        }
    }

    let summary: String?
    let lectures: [Lecture]

    private enum CodingKeys: String, CodingKey { case summary, lectures }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        lectures = try container.decode([Lecture].self, forKey: .lectures)
    }
}

/// One reading the plan placed: pages of one chapter (or the whole chapter)
/// after one lecture, and why this learner should read them there.
struct TextbookReadingPlacement: Equatable, Sendable {
    let lectureID: String
    let lectureNumber: Int
    let chapterSourceID: String
    let chapterNumber: Int
    let chapterTitle: String
    /// One-based pages within the chapter; nil reads the whole chapter.
    let pages: ClosedRange<Int>?
    /// The sections the pages hold, as the book titles them; the chapter's
    /// title when it is read whole.
    let title: String
    /// Why, for this learner, in one sentence addressed to them. Empty when the
    /// planner gave none: a reading keeps no invented reason.
    let reason: String
}

enum TextbookReadingPlanning {
    static let maximumReadingsPerLecture = 3
    static let maximumReasonCharacters = 400
    /// Characters of lecture material the planner reads, across the course,
    /// and the least any one lecture with text gets.
    static let lectureCharacterBudget = 160_000
    static let minimumLectureCharacters = 3_000
    static let writerMaxTokens = 6_000

    /// The plan checked against what was offered. Code decides everything that
    /// is identity: a lecture the course does not have and a handle the outline
    /// did not mint are dropped; parts of one reading from two chapters become
    /// two readings; consecutive sections of a chapter are one reading, and a
    /// gap between them makes two; a chapter handle, or a chapter with no
    /// sections, reads the whole chapter. A lecture keeps at most
    /// `maximumReadingsPerLecture` readings, in the planner's order, and never
    /// the same pages twice.
    static func placements(
        from draft: TextbookReadingDraft,
        outline: TextbookOutline,
        lectures: [TextbookLectureBrief]
    ) -> [TextbookReadingPlacement] {
        let lectureByNumber = Dictionary(lectures.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var chapterByHandle: [String: TextbookOutline.Chapter] = [:]
        var sectionByHandle: [String: (chapter: TextbookOutline.Chapter, index: Int)] = [:]
        for chapter in outline.chapters {
            chapterByHandle[chapter.handle.lowercased()] = chapter
            for (index, section) in chapter.sections.enumerated() {
                sectionByHandle[section.handle.lowercased()] = (chapter, index)
            }
        }

        var placementsByLecture: [String: [TextbookReadingPlacement]] = [:]
        var lectureOrder: [String] = []
        for entry in draft.lectures {
            guard let number = entry.lecture, let lecture = lectureByNumber[number] else { continue }
            if placementsByLecture[lecture.lectureID] == nil {
                placementsByLecture[lecture.lectureID] = []
                lectureOrder.append(lecture.lectureID)
            }
            for reading in entry.readings {
                let reason = cleanedReason(reading.why)
                // Group the named parts by chapter, in the order first named.
                var chapterOrder: [String] = []
                var wholeChapters: Set<String> = []
                var sectionIndexes: [String: Set<Int>] = [:]
                var chaptersByID: [String: TextbookOutline.Chapter] = [:]
                for raw in reading.parts {
                    let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let hit = sectionByHandle[handle] {
                        let id = hit.chapter.sourceID
                        if chaptersByID[id] == nil { chapterOrder.append(id) }
                        chaptersByID[id] = hit.chapter
                        sectionIndexes[id, default: []].insert(hit.index)
                    } else if let chapter = chapterByHandle[handle] {
                        let id = chapter.sourceID
                        if chaptersByID[id] == nil { chapterOrder.append(id) }
                        chaptersByID[id] = chapter
                        wholeChapters.insert(id)
                    }
                }
                for chapterID in chapterOrder {
                    guard let chapter = chaptersByID[chapterID] else { continue }
                    if wholeChapters.contains(chapterID) || chapter.sections.isEmpty {
                        placementsByLecture[lecture.lectureID, default: []].append(TextbookReadingPlacement(
                            lectureID: lecture.lectureID,
                            lectureNumber: lecture.number,
                            chapterSourceID: chapter.sourceID,
                            chapterNumber: chapter.number,
                            chapterTitle: chapter.title,
                            pages: nil,
                            title: chapter.title,
                            reason: reason
                        ))
                        continue
                    }
                    for run in consecutiveRuns(sectionIndexes[chapterID] ?? []) {
                        let sections = run.map { chapter.sections[$0] }
                        guard let first = sections.first, let last = sections.last else { continue }
                        placementsByLecture[lecture.lectureID, default: []].append(TextbookReadingPlacement(
                            lectureID: lecture.lectureID,
                            lectureNumber: lecture.number,
                            chapterSourceID: chapter.sourceID,
                            chapterNumber: chapter.number,
                            chapterTitle: chapter.title,
                            pages: first.pages.lowerBound...max(first.pages.lowerBound, last.pages.upperBound),
                            title: sections.map(\.title).joined(separator: " · "),
                            reason: reason
                        ))
                    }
                }
            }
        }

        var result: [TextbookReadingPlacement] = []
        let numberByLecture = Dictionary(lectures.map { ($0.lectureID, $0.number) }, uniquingKeysWith: { first, _ in first })
        for lectureID in lectureOrder.sorted(by: { (numberByLecture[$0] ?? 0) < (numberByLecture[$1] ?? 0) }) {
            var seen: Set<String> = []
            var kept = 0
            for placement in placementsByLecture[lectureID] ?? [] {
                let key = "\(placement.chapterSourceID)|\(placement.pages.map(TextbookReading.locator) ?? "whole")"
                guard kept < maximumReadingsPerLecture, seen.insert(key).inserted else { continue }
                result.append(placement)
                kept += 1
            }
        }
        return result
    }

    /// Sorted runs of consecutive indexes: [1, 2, 4] → [[1, 2], [4]].
    static func consecutiveRuns(_ indexes: Set<Int>) -> [[Int]] {
        var runs: [[Int]] = []
        for index in indexes.sorted() {
            if let last = runs.last?.last, last + 1 == index {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        return runs
    }

    static func cleanedReason(_ text: String) -> String {
        let collapsed = TextbookOutline.collapsed(text)
        guard collapsed.count > maximumReasonCharacters else { return collapsed }
        return String(collapsed.prefix(maximumReasonCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// How many characters of each lecture's material the planner reads: every
    /// lecture with text gets at least the minimum, and the rest of the budget
    /// is shared in proportion to length, so one long lecture cannot crowd out
    /// the others. Lecture Titles shares the rule with a smaller budget.
    static func lectureBudgets(
        lengths: [String: Int],
        total budget: Int = lectureCharacterBudget,
        minimum: Int = minimumLectureCharacters
    ) -> [String: Int] {
        let withText = lengths.filter { $0.value > 0 }
        guard !withText.isEmpty else { return [:] }
        let total = max(budget, minimum * withText.count)
        guard withText.values.reduce(0, +) > total else { return withText }
        let remainder = total - minimum * withText.count
        let excess = withText.mapValues { max(0, $0 - minimum) }
        let excessTotal = excess.values.reduce(0, +)
        var budgets: [String: Int] = [:]
        for (id, length) in withText {
            let share = excessTotal > 0
                ? Int(Double(remainder) * Double(excess[id] ?? 0) / Double(excessTotal))
                : 0
            budgets[id] = min(length, minimum + share)
        }
        return budgets
    }
}

extension TextbookReadingPlanning {
    /// A lecture's material as the planner reads it: the section headings its
    /// transcript carries (the `## ` lines the transcript formatter writes),
    /// then the text itself, sampled evenly through the lecture when it is
    /// longer than `budget` so the planner sees how it ends as well as how it
    /// begins.
    static func lectureMaterial(_ text: String, budget: Int) -> String {
        guard budget > 0, !text.isEmpty else { return "" }
        let headings = text.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("## ") else { return nil }
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
        var parts: [String] = []
        if headings.count > 1 {
            parts.append("Sections: " + headings.joined(separator: "; "))
        }
        parts.append(sampled(text, budget: budget))
        return parts.joined(separator: "\n")
    }

    /// `text` whole when it fits, else four evenly spaced windows of it.
    static func sampled(_ text: String, budget: Int) -> String {
        guard text.count > budget else { return text }
        let windows = 4
        let windowSize = max(1, budget / windows)
        let step = text.count / windows
        var pieces: [String] = []
        for index in 0..<windows {
            let start = text.index(text.startIndex, offsetBy: index * step)
            let available = text.distance(from: start, to: text.endIndex)
            let end = text.index(start, offsetBy: min(windowSize, available))
            pieces.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pieces.joined(separator: "\n[…]\n")
    }
}

// MARK: - Storage shape

/// How a textbook reading is stored: a `course_lecture_items` row with role
/// `reading` pointing at the chapter, and — when it is not the whole chapter —
/// at a `source_units` row naming its pages. The item's `label` carries the
/// reason. The unit is shared by every lecture that reads the same pages.
enum TextbookReading {
    /// `source_units.kind` for a run of pages within a source.
    static let unitKind = "pages"

    /// `"3-9"`: one-based pages within the source, first and last inclusive.
    static func locator(_ pages: ClosedRange<Int>) -> String {
        "\(pages.lowerBound)-\(pages.upperBound)"
    }

    /// The pages a `pages` unit's locator names, or nil when it names none.
    static func pages(fromLocator locator: String) -> ClosedRange<Int>? {
        let parts = locator.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let first = Int(parts[0]), let last = Int(parts[1]),
              first >= 1, last >= first else { return nil }
        return first...last
    }

    /// A unit is named by what it is, so the same pages of the same chapter
    /// are one row however many lectures read them, and two Macs that plan
    /// the same reading converge on one record.
    static func unitID(sourceID: String, pages: ClosedRange<Int>) -> String {
        "su-" + digest("source-unit-pages-v1", [sourceID, locator(pages)])
    }

    /// The same for the lecture item, so planning a book again replaces a
    /// reading with itself rather than adding a second copy.
    static func itemID(lectureID: String, sourceID: String, pages: ClosedRange<Int>?) -> String {
        "cli-tb-" + digest("textbook-reading-item-v1", [lectureID, sourceID, pages.map(locator) ?? "whole"])
    }

    static func unit(for placement: TextbookReadingPlacement) -> SourceUnit? {
        guard let pages = placement.pages else { return nil }
        return SourceUnit(
            id: unitID(sourceID: placement.chapterSourceID, pages: pages),
            sourceId: placement.chapterSourceID,
            kind: unitKind,
            locator: locator(pages),
            title: placement.title
        )
    }

    static func item(for placement: TextbookReadingPlacement, sortIndex: Int, createdAt: Date) -> CourseLectureItem {
        CourseLectureItem(
            id: itemID(lectureID: placement.lectureID, sourceID: placement.chapterSourceID, pages: placement.pages),
            lectureId: placement.lectureID,
            sourceId: placement.chapterSourceID,
            sourceUnitId: unit(for: placement)?.id,
            role: .reading,
            label: placement.reason.isEmpty ? nil : placement.reason,
            sortIndex: sortIndex,
            createdAt: createdAt
        )
    }

    private static func digest(_ namespace: String, _ fields: [String]) -> String {
        var bytes = Data(namespace.utf8)
        for field in fields {
            bytes.append(0)
            bytes.append(contentsOf: field.utf8)
        }
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }
}
