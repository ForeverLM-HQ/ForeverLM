import CryptoKit
import Foundation

/// What a course is to both the Mac and the iPhone: its stored quizzes, where
/// they stand on the path, how an answer is put to the grader and read back,
/// what a sitting scored, how far a video has been watched, and the gate that
/// holds back what follows an uncompleted quiz (docs/courses-design.md). The
/// iPhone target lists this file by name, so everything here is Foundation
/// and CryptoKit only; the Mac's writers, planners and chat live beside it in
/// `CourseQuiz.swift`, `LectureQuiz.swift` and `VideoQuiz.swift`.

/// A course's quizzes, written ahead of time and kept with the course, the
/// way a Khan Academy unit alternates lessons with practice, a quiz every few
/// lessons, and a unit test. The design record is docs/lecture-quiz-design.md.
///
/// A quiz is course structure, not a source: it lives in `course_quizzes`,
/// rides the Course record's payload to the learner's other Macs, and is
/// placed in the outline after the lecture named by `afterLectureID`. What a
/// learner did with it (the latest score, the questions they missed) is
/// per-member state and never enters the quiz.
struct CourseQuiz: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// The quiz after one lecture, about that lecture.
        case practice
        /// A quiz after every few lectures, across the lectures above it.
        case checkpoint
        /// The course test at the end, across the whole course.
        case test

        /// Order among quizzes that follow the same lecture.
        var placementOrder: Int {
            switch self {
            case .practice: return 0
            case .checkpoint: return 1
            case .test: return 2
            }
        }
    }

    enum Author: String, Codable, Sendable {
        /// Written by ForeverLM's quiz writers.
        case foreverlm
        /// Written by an assistant through `save_course_quiz`.
        case assistant
    }

    let id: String
    let courseID: String
    let kind: Kind
    var title: String
    /// The lectures the questions are about, in course order.
    var lectureIDs: [String]
    /// The lecture this quiz follows in the outline; nil puts it at the end.
    var afterLectureID: String?
    var questions: [CourseQuizQuestion]
    var author: Author
    let createdAt: Date
    var updatedAt: Date
    /// An SF Symbol for the quiz's tile, chosen by its writer for what the
    /// questions are about (schema 142). Nil draws the plain checklist.
    var symbol: String? = nil
    /// A small square JPEG drawn for the quiz on request (schema 142),
    /// carried in the quiz itself so it reaches the learner's other Macs in
    /// the Course record like the rest of the quiz. Nil shows the symbol.
    var artwork: Data? = nil

    /// Whether the title names the quiz's topics rather than the ladder's
    /// placeholder ("Quiz: <lecture>", "Quiz 3") it carried before naming.
    var hasTopicTitle: Bool {
        switch kind {
        case .practice: return !title.hasPrefix("Quiz: ")
        case .checkpoint: return !CourseQuizNaming.isNumberedCheckpointTitle(title)
        case .test: return true
        }
    }
}

/// How a quiz is named and pictured: a short title from the topics its
/// questions cover and an SF Symbol, returned by the writer with the
/// questions, and a drawn picture when the learner asks for one.
enum CourseQuizNaming {
    static let maximumTitleCharacters = 60
    /// The stored picture's side in pixels: the tile is 36 × 36 points, so
    /// 160 covers it at 2x with room to crop, and stays a few kilobytes.
    static let artworkPixelSize = 160
    /// A picture larger than this is not kept: it rides the Course record,
    /// which also carries every other quiz of the course.
    static let maximumArtworkBytes = 40_000

    /// "Quiz 3", the ladder's name for a checkpoint.
    static func isNumberedCheckpointTitle(_ title: String) -> Bool {
        let parts = title.split(separator: " ")
        return parts.count == 2 && parts[0] == "Quiz" && Int(parts[1]) != nil
    }

    /// A writer's title cleaned to one short line, or nil when there is none
    /// worth showing. Quotes, a trailing period and a "Quiz:" prefix go.
    static func cleanTitle(_ raw: String?) -> String? {
        guard var title = raw?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        for prefix in ["Quiz:", "quiz:"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        while title.hasSuffix(".") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isNumberedCheckpointTitle(title) else { return nil }
        if title.count > maximumTitleCharacters {
            let cut = title.prefix(maximumTitleCharacters)
            title = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut))
        }
        return title
    }

    /// A writer's symbol name, shaped like one (`atom`, `bolt.heart.fill`);
    /// whether this system has it is the caller's check.
    static func cleanSymbol(_ raw: String?) -> String? {
        guard let symbol = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !symbol.isEmpty, symbol.count <= 60,
              symbol.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }),
              symbol.first?.isLetter == true || symbol.first?.isNumber == true else { return nil }
        return symbol
    }
}

/// One question: what to ask, its reference answer, and the stretch of a
/// lecture's source it rests on.
struct CourseQuizQuestion: Codable, Equatable, Identifiable, Sendable {
    /// How far up a textbook problem set a question sits (product owner,
    /// 2026-09-26: "working up from basics to pretty challenging"). A quiz
    /// asks its questions in this order.
    enum Level: String, Codable, CaseIterable, Comparable, Sendable {
        case recall
        case explain
        case apply
        case challenge

        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        var displayName: String {
            switch self {
            case .recall: return "Recall"
            case .explain: return "Explain"
            case .apply: return "Apply"
            case .challenge: return "Challenge"
            }
        }
    }

    /// Named by what the question asks, not where it sits
    /// (`CourseQuizPlanning.questionID`), so the Memory item it is recorded on
    /// follows it when a rewrite reorders the quiz. Unique within its quiz. A
    /// quiz stored before content ids keeps its positional `q1`, `q2`, …
    let id: String
    /// The source the question is about: a lecture's video, notes or
    /// lesson, or a reading assigned with it (a textbook chapter).
    let sourceID: String?
    /// Numbered lines of that source's text (`CourseQuizPlanning.lines`).
    let firstLine: Int?
    let lastLine: Int?
    /// Where to rewatch in the video, when the source is timed: when the
    /// lecture says the quote (`LectureQuizTimeline`), or where the stretch
    /// starts for a question without one.
    var startSeconds: Double?
    let question: String
    let answer: String
    let keyPoints: [String]
    /// The source's own words the question rests on, for a Memory anchor.
    let quote: String?
    /// The level's name as stored, kept as text so a level a later build
    /// adds still decodes here (the quiz rides the synced Course record).
    /// Nil on a quiz written before levels (2026-09-26).
    var levelName: String? = nil
    /// The picture the question is shown with, chosen when the quiz was
    /// written; nil leaves pictures to the tutor. Nil on a quiz written
    /// before pictures (2026-09-27).
    var picture: CourseQuizPicture? = nil
    /// The page of its source the stretch starts on, for a reading's
    /// question, so the tutor can send the learner back to it. Nil for a
    /// lecture's question, and on a quiz written before readings were quizzed
    /// (2026-09-27).
    var page: Int? = nil

    var level: Level? { levelName.flatMap(Level.init(rawValue:)) }

    /// The same question under another id.
    func identified(as id: String) -> CourseQuizQuestion {
        CourseQuizQuestion(
            id: id,
            sourceID: sourceID,
            firstLine: firstLine,
            lastLine: lastLine,
            startSeconds: startSeconds,
            question: question,
            answer: answer,
            keyPoints: keyPoints,
            quote: quote,
            levelName: levelName,
            picture: picture,
            page: page
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, firstLine, lastLine, startSeconds, question, answer, keyPoints, quote, picture, page
        case levelName = "level"
    }
}

/// A picture a quiz question carries: whatever makes the question's point
/// clear. The product owner, 2026-09-27: "during quizzes, I feel like it should also try
/// to show images whenever that's helpful", and a quiz Claude writes should
/// "grab images as well, from the videos, but make their points clear"; then
/// the same day, that it be "fully implemented … including generated images;
/// whether generated in foreverlm or in an external app and then ingested via
/// mcp". Three kinds, one field:
///
/// - a picture inside a source (`SourceImageReference`): a lecture video's
///   frame at a time, a reading's page cropped to its figure, an image of an
///   EPUB chapter;
/// - a picture in ForeverLM's image store (`foreverlm://image/generated/<id>`,
///   `GeneratedImageReference`): drawn by ForeverLM for the question, drawn
///   with `generate_image`, or made in another app and kept with `save_image`;
/// - a picture briefed for ForeverLM to draw, which has no image yet.
///
/// Chosen when the quiz is written, by a writer that read the lecture's
/// slides and the reading's figures or an assistant that looked at the
/// picture, so the quiz shows it every time rather than when the tutor
/// happens to think of it.
struct CourseQuizPicture: Codable, Equatable, Sendable {
    enum Placement: String, Codable, Sendable {
        /// Above the question: the learner needs to see it to answer.
        case question
        /// With the grade: it shows the answer, so it waits for an attempt.
        case answer
    }

    /// A `foreverlm://image/...` address: a source's picture (for a lecture
    /// video the frame at a time, cropped to what matters — a moment rather
    /// than a slide number, so a Mac that never captured the slides draws it
    /// from the video too), or one version of a stored image. Empty while a
    /// briefed picture waits to be drawn: a build from before briefs then
    /// reads a picture it cannot show, rather than failing the whole quiz.
    var image: String
    /// What the picture shows, in a few words that do not give the answer
    /// away: its alt text.
    let caption: String?
    /// The placement's name as stored, kept as text so a placement a later
    /// build adds still decodes (the quiz rides the synced Course record).
    let placementName: String
    /// For a picture ForeverLM draws: what it must show, the writer's brief.
    /// Kept once drawn, as what the drawing was made from.
    var brief: String? = nil

    init(reference: SourceImageReference, caption: String?, placement: Placement) {
        self.init(image: reference.urlString, caption: caption, placement: placement)
    }

    /// A picture in the image store, by the `foreverlm://image/generated/<id>`
    /// address of the version shown.
    init(storedImage url: String, caption: String?, placement: Placement, brief: String? = nil) {
        self.init(image: url, caption: caption, placement: placement, brief: brief)
    }

    /// A picture for ForeverLM to draw: nothing is shown until it is.
    static func awaitingDrawing(brief: String, caption: String?, placement: Placement) -> CourseQuizPicture {
        CourseQuizPicture(image: "", caption: caption, placement: placement, brief: brief)
    }

    private init(image: String, caption: String?, placement: Placement, brief: String? = nil) {
        self.image = image
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.caption = caption?.isEmpty == false ? caption : nil
        placementName = placement.rawValue
        let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.brief = brief?.isEmpty == false ? brief : nil
    }

    /// An unknown placement waits for the answer: a picture shown too late
    /// costs less than one that gives the answer away.
    var placement: Placement { Placement(rawValue: placementName) ?? .answer }

    var reference: SourceImageReference? { SourceImageReference(urlString: image) }

    /// The version id of a picture in the image store, read with
    /// `GeneratedImageReference`'s grammar (`foreverlm://image/generated/<id>`)
    /// but without the type, because the phone compiles this file and not the
    /// store.
    var storedImageID: String? { Self.storedImageID(in: image) }

    /// A briefed picture not drawn yet.
    var isAwaitingDrawing: Bool { image.isEmpty && brief != nil }

    /// Whether there is a picture to show: a source's picture or a stored one.
    var isShowable: Bool { reference != nil || storedImageID != nil }

    /// The line the chat shows, or nil when there is nothing to show yet or
    /// the address no longer parses.
    func markdown(fallbackAlt: String) -> String? {
        let alt = caption ?? fallbackAlt
        if let reference { return reference.markdown(alt: alt) }
        guard storedImageID != nil else { return nil }
        let cleaned = alt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "![\(cleaned.isEmpty ? "Picture" : cleaned)](\(image))"
    }

    /// The briefed picture, drawn: the stored version's address in place of
    /// the empty one, caption, placement and brief kept.
    func drawn(as url: String) -> CourseQuizPicture {
        CourseQuizPicture(image: url, caption: caption, placement: placement, brief: brief)
    }

    enum CodingKeys: String, CodingKey {
        case image, caption, brief
        case placementName = "placement"
    }

    static let storedImageSegment = "generated"

    /// The version id in a `foreverlm://image/generated/<id>` address.
    static func storedImageID(in text: String) -> String? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == SourceImageReference.scheme,
              components.host?.lowercased() == SourceImageReference.host else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2, segments[0].lowercased() == storedImageSegment else { return nil }
        let id = segments[1].lowercased()
        guard (8...64).contains(id.count),
              id.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) || $0 == "-" }) else { return nil }
        return id
    }

    static func storedImageURL(id: String) -> String {
        "\(SourceImageReference.scheme)://\(SourceImageReference.host)/\(storedImageSegment)/\(id)"
    }

    /// A picture as `save_course_quiz` and `set_course_quiz_picture` take it:
    /// an object with one of
    /// - `image`: the Markdown image line or `foreverlm://image` address that
    ///   `show_source_image`, `generate_image`, `save_image` or `list_images`
    ///   returned;
    /// - `image_id`: an image in the store, from `generate_image`,
    ///   `save_image` or `list_images` (`resolveStoredImage` names the
    ///   version it shows, or nil when this Mac holds no such image);
    /// - `at`: a time in the question's source video, with an optional `crop`;
    /// - `page`: a page of the question's source (a reading's PDF), with an
    ///   optional `crop` to its figure;
    /// - `brief`: what a picture ForeverLM draws for the question must show;
    /// plus `caption` and `show_with`. Nil when none was given; a message when
    /// one was given wrong.
    static func parse(
        _ raw: Any?,
        sourceID: String?,
        resolveStoredImage: (String) -> String? = { _ in nil }
    ) -> Result<CourseQuizPicture?, PictureError> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        let object: [String: Any]
        if let text = raw as? String {
            object = ["image": text]
        } else if let given = raw as? [String: Any] {
            object = given
        } else {
            return .failure(PictureError("picture must be an object with image, image_id, at, page or brief, and show_with."))
        }
        let placementText = (object["show_with"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var placement = Placement.question
        if let placementText, !placementText.isEmpty {
            guard let known = Placement(rawValue: placementText) else {
                return .failure(PictureError("picture.show_with must be question or answer."))
            }
            placement = known
        }
        var caption = (object["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let crop = SourceImageReference.cropArgument(object["crop"])
        if object["crop"] != nil, crop == nil {
            return .failure(PictureError("picture.crop must be {x, y, width, height}, each a fraction between 0 and 1 of the frame or page from its top-left corner."))
        }
        let brief = (object["brief"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let image = (object["image"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            if let found = imageReference(in: image) {
                if caption?.isEmpty != false { caption = found.alt }
                return .success(CourseQuizPicture(reference: found.reference, caption: caption, placement: placement))
            }
            if let found = storedImage(in: image) {
                guard let version = resolveStoredImage(found.id) else {
                    return .failure(PictureError("picture.image names image \(found.id), which is not on this Mac. list_images names the images it holds; save_image keeps one made elsewhere."))
                }
                if caption?.isEmpty != false { caption = found.alt }
                return .success(CourseQuizPicture(storedImage: storedImageURL(id: version), caption: caption, placement: placement))
            }
            return .failure(PictureError("picture.image must be a Markdown image line or foreverlm://image address that show_source_image, generate_image, save_image or list_images returned."))
        }
        if let named = (object["image_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            let id = storedImage(in: named)?.id ?? named.lowercased()
            guard let version = resolveStoredImage(id) else {
                return .failure(PictureError("picture.image_id \(named) is no image on this Mac. generate_image draws one, save_image keeps one made elsewhere, and list_images names them."))
            }
            return .success(CourseQuizPicture(storedImage: storedImageURL(id: version), caption: caption, placement: placement, brief: brief?.isEmpty == false ? brief : nil))
        }
        if object["at"] != nil {
            guard let sourceID else {
                return .failure(PictureError("picture.at needs the question's source_id: the video the time is in."))
            }
            guard let seconds = SourceImageReference.timestampSeconds(object["at"]) else {
                return .failure(PictureError("picture.at must be a time in the video: seconds (265) or a clock reading (4:25)."))
            }
            return .success(CourseQuizPicture(
                reference: SourceImageReference(sourceID: sourceID, location: .moment(seconds), crop: crop),
                caption: caption,
                placement: placement
            ))
        }
        if let rawPage = object["page"] {
            guard let sourceID else {
                return .failure(PictureError("picture.page needs the question's source_id: the reading the page is in."))
            }
            guard let page = (rawPage as? NSNumber)?.intValue ?? (rawPage as? String).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
                  page >= 1 else {
                return .failure(PictureError("picture.page must be a page of the question's source, counted from 1."))
            }
            return .success(CourseQuizPicture(
                reference: SourceImageReference(sourceID: sourceID, location: .page(page), crop: crop),
                caption: caption,
                placement: placement
            ))
        }
        if let brief, !brief.isEmpty {
            return .success(.awaitingDrawing(brief: brief, caption: caption, placement: placement))
        }
        return .failure(PictureError("picture needs image (the line show_source_image, generate_image or save_image returned), image_id (an image from generate_image, save_image or list_images), at (a time in the question's video), page (a page of the question's reading) or brief (a picture for ForeverLM to draw)."))
    }

    /// The reference in a Markdown image line, or a bare reference URL.
    static func imageReference(in text: String) -> (reference: SourceImageReference, alt: String?)? {
        if let bare = SourceImageReference(urlString: text) { return (bare, nil) }
        guard let (url, alt) = markdownImage(in: text),
              let reference = SourceImageReference(urlString: url) else { return nil }
        return (reference, alt)
    }

    /// The stored image's id in a Markdown image line or a bare
    /// `foreverlm://image/generated/<id>` address.
    static func storedImage(in text: String) -> (id: String, alt: String?)? {
        if let bare = storedImageID(in: text) { return (bare, nil) }
        guard let (url, alt) = markdownImage(in: text), let id = storedImageID(in: url) else { return nil }
        return (id, alt)
    }

    /// The address and alt text of `![alt](address)`.
    private static func markdownImage(in text: String) -> (url: String, alt: String?)? {
        guard let open = text.range(of: "!["),
              let close = text.range(of: "](", range: open.upperBound..<text.endIndex),
              let end = text.range(of: ")", range: close.upperBound..<text.endIndex) else { return nil }
        let alt = String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(text[close.upperBound..<end.lowerBound]), alt.isEmpty ? nil : alt)
    }

    struct PictureError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

// MARK: - Identity and placement

/// The parts of quiz planning the course page needs: what a quiz is named and
/// where it stands. Writing quizzes extends this in `CourseQuiz.swift`.
enum CourseQuizPlanning {
    /// A quiz ForeverLM writes is named by what it is, so two Macs writing a
    /// course's quizzes converge on one record per quiz instead of two.
    static func practiceID(courseID: String, lectureID: String) -> String {
        digestID("course-quiz-practice-v1", [courseID, lectureID])
    }

    static func checkpointID(courseID: String, lectureIDs: [String]) -> String {
        digestID("course-quiz-checkpoint-v1", [courseID] + lectureIDs)
    }

    static func testID(courseID: String) -> String {
        digestID("course-quiz-test-v1", [courseID])
    }

    /// A question is named by the source it is about and what it asks, never
    /// by its place in the quiz. Its Memory item is named after it
    /// (`course-quiz-<quizID>-<questionID>`), so a rewrite sorted by level,
    /// or an assistant's save that adds a question ahead of it, leaves each
    /// question on its own item. Its lines and level are left out: a rewrite
    /// that re-anchors or relevels the same question keeps the item.
    static func questionID(sourceID: String?, question: String) -> String {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return "q-\(digest("course-quiz-question-v1", [sourceID ?? "", text]).prefix(16))"
    }

    private static func digestID(_ namespace: String, _ fields: [String]) -> String {
        "cq-\(digest(namespace, fields).prefix(32))"
    }

    private static func digest(_ namespace: String, _ fields: [String]) -> String {
        var bytes = Data(namespace.utf8)
        for field in fields {
            bytes.append(0)
            bytes.append(contentsOf: field.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// A course's quizzes in outline order, grouped by the lecture each
    /// follows: practice, then a checkpoint, then the test. A quiz whose
    /// lecture is no longer in the course follows the last lecture it covers
    /// that still is, or ends the course.
    static func placements(
        quizzes: [CourseQuiz],
        lectureOrder: [String]
    ) -> (afterLecture: [String: [CourseQuiz]], atEnd: [CourseQuiz]) {
        let present = Set(lectureOrder)
        var afterLecture: [String: [CourseQuiz]] = [:]
        var atEnd: [CourseQuiz] = []
        for quiz in quizzes {
            let anchor = [quiz.afterLectureID].compactMap { $0 }.first(where: present.contains)
                ?? quiz.lectureIDs.last(where: present.contains)
            if let anchor {
                afterLecture[anchor, default: []].append(quiz)
            } else {
                atEnd.append(quiz)
            }
        }
        func sorted(_ list: [CourseQuiz]) -> [CourseQuiz] {
            list.sorted { ($0.kind.placementOrder, $0.title) < ($1.kind.placementOrder, $1.title) }
        }
        return (afterLecture.mapValues(sorted), sorted(atEnd))
    }
}

// MARK: - Sittings and grading

/// How one question of a sitting ended.
enum LectureQuizOutcome: Equatable, Sendable {
    case graded(VideoQuizVerdict)
    case remembered
    case forgot
    case skipped

    var isRight: Bool {
        switch self {
        case .graded(.correct), .remembered: return true
        default: return false
        }
    }
}

/// A finished sitting, as the lecture's quiz row shows it. The latest one is
/// kept per lecture as the synced preference `lectureQuiz.score.<sourceID>`,
/// so it follows the learner across launches and Macs and never enters a
/// team's copy of the course.
struct LectureQuizScore: Equatable, Sendable {
    let right: Int
    let total: Int
    let takenAt: Date
    /// When a sitting of this quiz first passed. Carried from sitting to
    /// sitting (`recorded(after:)`), so a worse retake never takes the
    /// learner's mastery mark back (docs/courses-design.md, "The gate").
    let passedAt: Date?

    init(right: Int, total: Int, takenAt: Date, passedAt: Date? = nil) {
        self.right = right
        self.total = total
        self.takenAt = takenAt
        self.passedAt = passedAt
    }

    init(outcomes: [LectureQuizOutcome], takenAt: Date = Date()) {
        self.init(right: outcomes.filter(\.isRight).count, total: outcomes.count, takenAt: takenAt)
    }

    var label: String { "\(right) of \(total) right" }

    /// The latest sitting's mastery as a bounded fraction for the course
    /// row's trailing score ring. A malformed zero-total value is
    /// empty rather than dividing by zero, and corrupt out-of-range counts
    /// cannot overdraw the ring.
    var fractionRight: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(right) / Double(total), 0), 1)
    }

    /// A full score turns the score ring into the course's green done mark.
    var isFullyRight: Bool { total > 0 && right >= total }

    /// Whether this result belongs to the quiz's current question set. A quiz
    /// rewrite keeps its earlier result as completion history, but a different
    /// total must be labelled as a previous-version score rather than making
    /// the rewritten quiz look as short as the old one.
    func matches(questionCount: Int) -> Bool { total == questionCount }

    /// The answers a sitting of `total` questions needs right to pass: three
    /// in four, Khan Academy's "get 3 of 4 questions to level up" (product owner,
    /// 2026-09-27: gate the next lectures "until the student actually gets
    /// things right"). Rounded up, so a 3-question quiz needs all three.
    static func rightNeededToPass(total: Int) -> Int {
        (total * 3 + 3) / 4
    }

    /// Whether this sitting passed on its own.
    var passes: Bool {
        total > 0 && right >= Self.rightNeededToPass(total: total)
    }

    /// Whether the quiz has been passed: by this sitting, or by an earlier one.
    var hasPassed: Bool {
        passedAt != nil || passes
    }

    /// This sitting as it is kept after `previous`: it keeps the first pass,
    /// whichever sitting made it.
    func recorded(after previous: LectureQuizScore?) -> LectureQuizScore {
        let earlierPass = previous.flatMap { $0.passedAt ?? ($0.passes ? $0.takenAt : nil) }
        return LectureQuizScore(
            right: right,
            total: total,
            takenAt: takenAt,
            passedAt: earlierPass ?? passedAt ?? (passes ? takenAt : nil)
        )
    }

    static let preferenceKeyPrefix = "lectureQuiz.score."

    static func preferenceKey(sourceID: String) -> String {
        preferenceKeyPrefix + sourceID
    }

    /// `courseQuiz.score.<quizID>`: the latest sitting of a stored course
    /// quiz (`CourseQuiz`), kept the same way, one row per quiz.
    static let courseQuizPreferenceKeyPrefix = "courseQuiz.score."

    static func preferenceKey(courseQuizID: String) -> String {
        courseQuizPreferenceKeyPrefix + courseQuizID
    }

    /// The preference row's value: a property-list dictionary.
    var preferenceValue: [String: Any] {
        var value: [String: Any] = ["right": right, "total": total, "takenAt": takenAt.timeIntervalSince1970]
        if let passedAt { value["passedAt"] = passedAt.timeIntervalSince1970 }
        return value
    }

    /// Reads a preference row back; nil for anything that is not a sitting
    /// (no questions, more right than asked). A row written before passes
    /// were kept has no `passedAt`; its own score still says whether it passed.
    init?(preferenceValue value: Any) {
        guard let dictionary = value as? [String: Any],
              let right = (dictionary["right"] as? NSNumber)?.intValue,
              let total = (dictionary["total"] as? NSNumber)?.intValue,
              total > 0, right >= 0, right <= total else { return nil }
        let takenAt = (dictionary["takenAt"] as? NSNumber)?.doubleValue ?? 0
        let passedAt = (dictionary["passedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        self.init(right: right, total: total, takenAt: Date(timeIntervalSince1970: takenAt), passedAt: passedAt)
    }

    /// Every stored score, keyed by the lecture video's source id. One scan
    /// of the defaults dictionary finds the runtime-built keys.
    static func scoresFromDefaults(
        _ defaults: UserDefaults = .standard,
        prefix: String = preferenceKeyPrefix
    ) -> [String: LectureQuizScore] {
        var scores: [String: LectureQuizScore] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let sourceID = String(key.dropFirst(prefix.count))
            guard !sourceID.isEmpty, let score = LectureQuizScore(preferenceValue: value) else { continue }
            scores[sourceID] = score
        }
        return scores
    }
}

/// How a typed answer did against the checkpoint's reference answer.
enum VideoQuizVerdict: String, Codable, Equatable, Sendable {
    case correct
    case partial
    case incorrect

    /// Where the answer leaves the question's Memory item: a miss comes back
    /// soon, a partial answer sooner than a clean one.
    var scheduleRating: MemoryScheduleRating {
        switch self {
        case .correct: return .good
        case .partial: return .hard
        case .incorrect: return .again
        }
    }

    var score: Double {
        switch self {
        case .correct: return 1
        case .partial: return 0.5
        case .incorrect: return 0
        }
    }
}

struct VideoQuizGrade: Codable, Equatable, Sendable {
    let verdict: VideoQuizVerdict
    let feedback: String
}

/// A learner's answer as the grader reads it: the answer and, once the
/// grader has followed it up, its follow-up question and the learner's
/// reply. The product owner, 2026-09-27: "maybe it should ask for a small follow up to
/// clarify; instead of just being like 'partly right'". Only a first try the
/// learner can reply to may be followed up, so a question asks at most one.
struct QuizAnswerAttempt: Equatable, Sendable {
    struct FollowUp: Equatable, Sendable {
        let question: String
        let reply: String
    }

    let answer: String
    var followUp: FollowUp? = nil
    /// Whether the learner can answer a follow-up where they answered. In a
    /// quiz's chat and the iPhone's quiz they can; false grades the answer as
    /// it stands.
    var learnerCanReply = false

    var mayFollowUp: Bool { learnerCanReply && followUp == nil }

    /// The attempt as Memory keeps it with the question.
    var memoryText: String {
        guard let followUp else { return answer }
        return "\(answer)\nFollow-up: \(followUp.question)\n\(followUp.reply)"
    }
}

/// What the grader made of an attempt: a grade, or, on a first try that is
/// on the right track but short of what the question asks, one follow-up
/// question instead. A follow-up is no grade: nothing is kept until the
/// reply has been graded with the answer.
enum QuizGraderResult: Equatable, Sendable {
    case graded(VideoQuizGrade)
    case followUp(String)
}

/// The grader's JSON, before `result(for:)` reads it. `asks`, the model's
/// note of what the question asks for, is written only to steady its verdict
/// and is not decoded.
struct QuizGraderReply: Decodable, Equatable, Sendable {
    let verdict: VideoQuizVerdict?
    let feedback: String?
    let followUp: String?

    enum CodingKeys: String, CodingKey {
        case verdict, feedback
        case followUp = "follow_up"
    }

    /// The raw reply decoded, or nil when it is not the grader's JSON.
    init?(reply: String) {
        guard let decoded: QuizGraderReply = try? MemoryReviewPlanning.decodeJSON(reply) else { return nil }
        self = decoded
    }

    /// What the reply means for the attempt it answers, or nil when it is no
    /// usable grade. A follow-up counts only where the attempt may have one,
    /// and only where the grader has not also called the answer right or
    /// wrong; a grade needs its verdict and some feedback.
    func result(for attempt: QuizAnswerAttempt) -> QuizGraderResult? {
        if attempt.mayFollowUp, verdict == nil || verdict == .partial,
           let followUp = followUp?.trimmingCharacters(in: .whitespacesAndNewlines), !followUp.isEmpty {
            return .followUp(followUp)
        }
        guard let verdict,
              let feedback = feedback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !feedback.isEmpty else { return nil }
        return .graded(VideoQuizGrade(verdict: verdict, feedback: feedback))
    }
}

/// What the grader (`Prompts.videoQuizGrader`) is sent and may send back, the
/// same on the Mac and the iPhone.
enum QuizGraderExchange {
    static let maxTokens = 700

    /// What the grader reads for one attempt: the question, its reference
    /// answer and key points, the stretch it covers, the learner's answer,
    /// and whether a follow-up may be asked; after one, the follow-up and the
    /// learner's reply.
    static func message(
        question: String,
        referenceAnswer: String,
        keyPoints: [String],
        coveredTranscript: String,
        attempt: QuizAnswerAttempt
    ) -> String {
        var parts = [
            "Question: \(question)",
            "Reference answer: \(referenceAnswer)",
        ]
        if !keyPoints.isEmpty {
            parts.append("Key points:\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("Transcript of the stretch:\n\(coveredTranscript)")
        parts.append("Learner's answer: \(attempt.answer)")
        if let followUp = attempt.followUp {
            parts.append("Your follow-up: \(followUp.question)")
            parts.append("Learner's reply: \(followUp.reply)")
            parts.append("This is their reply to your follow-up. Grade the answer and the reply together, as one answer, and ask nothing more.")
        } else if attempt.mayFollowUp {
            parts.append("This is their first try, and they can reply to you: if the answer is on the right track but would be partial, you may ask one follow-up instead of grading.")
        } else {
            parts.append("They cannot reply to a follow-up here: grade the answer as it stands.")
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Watching

/// How far the learner has watched a video, JSON-encoded into
/// `sources.reading_position_locator` — the same slot the EPUB reader uses for
/// its scroll locator — so it rides the existing source sync round trip and
/// feeds the "In progress" read filter with no schema change. Seconds are
/// stored whole so repeated saves of the same position compare equal as strings.
///
/// The watched mark only grows, on this Mac and across the sync merge, so a
/// stale copy can never make a watched video look unwatched. **Mark as Not
/// Watched** is the one way down (product owner, 2026-09-27): it starts a new
/// *epoch*, `unwatchedAt`, and progress stamped with an older epoch — or none —
/// no longer counts wherever the two meet (`merged(with:)`). Every locator
/// written before the first mark carries no epoch and encodes exactly as it
/// always did.
struct VideoWatchProgress: Codable, Equatable {
    /// Last playhead position, for resuming playback.
    var positionSeconds: Double
    /// Furthest playhead position reached — the "how much have I watched" high-water mark.
    var watchedSeconds: Double
    /// Player-reported duration; nil until the watch page first reports it.
    var durationSeconds: Double?
    /// When the learner last marked the video not watched; nil until they do.
    /// Whole seconds, like the rest, and carried by every later save.
    var unwatchedAt: Date?

    /// The epoch's JSON key. No other locator encoding contains it, so a
    /// substring test tells the rare locator that needs decoding from the rest.
    static let unwatchedAtKey = "unwatchedAt"

    init(positionSeconds: Double, watchedSeconds: Double, durationSeconds: Double?, unwatchedAt: Date? = nil) {
        let position = max(0, positionSeconds.rounded())
        self.positionSeconds = position
        self.watchedSeconds = max(position, max(0, watchedSeconds.rounded()))
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            self.durationSeconds = durationSeconds.rounded()
        } else {
            self.durationSeconds = nil
        }
        if let unwatchedAt, unwatchedAt.timeIntervalSinceReferenceDate.isFinite {
            self.unwatchedAt = Date(timeIntervalSinceReferenceDate: unwatchedAt.timeIntervalSinceReferenceDate.rounded())
        } else {
            self.unwatchedAt = nil
        }
    }

    init?(encoded: String?) {
        guard let encoded,
              let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.positionSeconds.isFinite,
              decoded.watchedSeconds.isFinite else { return nil }
        self = Self(
            positionSeconds: decoded.positionSeconds,
            watchedSeconds: decoded.watchedSeconds,
            durationSeconds: decoded.durationSeconds,
            unwatchedAt: decoded.unwatchedAt
        )
    }

    var encoded: String? {
        // Sorted keys so equal values encode to identical strings — the
        // persistence layer dedupes repeat writes by string comparison.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Watched share of the video, when the duration is known.
    var fractionWatched: Double? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return min(max(watchedSeconds / durationSeconds, 0), 1)
    }

    /// Within the final stretch — treated as fully watched for display and
    /// restart-instead-of-resume decisions (mirrors how video apps round up the
    /// outro). Never before anything is watched: a video half a minute long
    /// is inside its own final stretch from the start, and a Mark as Not
    /// Watched keeps the duration it knew.
    var isEssentiallyWatched: Bool {
        guard watchedSeconds > 0, let fractionWatched, let durationSeconds else { return false }
        return fractionWatched >= 0.95 || durationSeconds - watchedSeconds <= 30
    }

    /// Whether any of the video has been watched. False only for a Mark as Not
    /// Watched that nothing has played past since: that locator holds the
    /// epoch and nothing a reader would resume from.
    var recordsWatching: Bool { watchedSeconds > 0 }

    /// Row label: "Watched" once essentially finished, else a percentage while
    /// the duration is known, else a bare minute count.
    var displayLabel: String? {
        if isEssentiallyWatched { return "Watched" }
        if let fractionWatched {
            let percent = Int((fractionWatched * 100).rounded())
            guard percent >= 1 else { return nil }
            return "\(min(percent, 99))% watched"
        }
        let minutes = Int(watchedSeconds / 60)
        guard minutes >= 1 else { return nil }
        return "\(minutes) min watched"
    }

    /// Where to reopen the player, or nil to start from the top: a trivial head
    /// start isn't worth restoring, and an essentially finished video restarts.
    var resumeSeconds: Double? {
        guard positionSeconds >= 30 else { return nil }
        if let durationSeconds, durationSeconds > 0 {
            guard positionSeconds < durationSeconds - 30,
                  positionSeconds / durationSeconds < 0.97 else { return nil }
        }
        return positionSeconds
    }

    /// The next progress when the player reports `time`: the playhead moves,
    /// the watched mark never falls, and the epoch carries on.
    func advanced(to time: Double, durationSeconds reportedDuration: Double?) -> VideoWatchProgress {
        VideoWatchProgress(
            positionSeconds: time,
            watchedSeconds: max(watchedSeconds, time),
            durationSeconds: reportedDuration ?? durationSeconds,
            unwatchedAt: unwatchedAt
        )
    }

    /// **Mark as Not Watched**: nothing watched, nothing to resume, and an
    /// epoch later than any the video has had, so it outranks every earlier
    /// save on every device, whatever their clocks say. The duration stays; it
    /// is a fact about the video, not about the watching.
    static func notWatched(from current: VideoWatchProgress?, at date: Date) -> VideoWatchProgress {
        // Compared in whole seconds, as stored: a second mark within the
        // second of the first must still be a later epoch than it.
        var epoch = date.timeIntervalSinceReferenceDate.rounded()
        if let previous = current?.unwatchedAt?.timeIntervalSinceReferenceDate, previous >= epoch {
            epoch = previous + 1
        }
        return VideoWatchProgress(
            positionSeconds: 0,
            watchedSeconds: 0,
            durationSeconds: current?.durationSeconds,
            unwatchedAt: Date(timeIntervalSinceReferenceDate: epoch)
        )
    }

    /// **Mark as Watched**: watched to the end, reopening from the top the way
    /// a finished video does (`resumeSeconds`). Nil until the length is known,
    /// which the player reports the first time the video plays.
    func markedWatched() -> VideoWatchProgress? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return VideoWatchProgress(
            positionSeconds: durationSeconds,
            watchedSeconds: durationSeconds,
            durationSeconds: durationSeconds,
            unwatchedAt: unwatchedAt
        )
    }

    /// Join two copies of one video's progress; `self` is the copy whose resume
    /// position stands. The later Mark as Not Watched wins outright, since
    /// everything the other copy holds was watched before it. Within one
    /// epoch the watched high-water mark is the larger of the two. The join is
    /// the same whichever device computes it, so copies converge.
    func merged(with other: VideoWatchProgress) -> VideoWatchProgress {
        let mine = unwatchedAt ?? .distantPast
        let theirs = other.unwatchedAt ?? .distantPast
        if theirs > mine { return other }
        if mine > theirs { return self }
        return VideoWatchProgress(
            positionSeconds: positionSeconds,
            watchedSeconds: max(watchedSeconds, other.watchedSeconds),
            durationSeconds: durationSeconds ?? other.durationSeconds,
            unwatchedAt: unwatchedAt
        )
    }

    /// `merged(with:)` over encoded locators. A copy that is not a video's
    /// progress (nil, an article or EPUB locator) is absent knowledge: the
    /// other is kept as written, or the owner's when neither is one. A side
    /// that wins outright is returned verbatim, so an answer that changes
    /// nothing compares equal to what came in and republishes nothing.
    static func mergedLocator(owner: String?, other: String?) -> String? {
        guard let otherProgress = VideoWatchProgress(encoded: other) else { return owner }
        guard let ownerProgress = VideoWatchProgress(encoded: owner) else { return other }
        let merged = ownerProgress.merged(with: otherProgress)
        if merged == ownerProgress { return owner }
        if merged == otherProgress { return other }
        return merged.encoded
    }

    /// What a reader's live tracker continues from: its own copy, joined with
    /// what the store now holds. A Mark as Not Watched made while the video was
    /// open (from a menu, over MCP, or on another device) supersedes the
    /// tracker; a Mark as Watched lifts its watched mark.
    static func continuing(_ live: VideoWatchProgress?, over stored: VideoWatchProgress?) -> VideoWatchProgress? {
        guard let live else { return stored }
        guard let stored else { return live }
        return live.merged(with: stored)
    }

    /// The Mark as Not Watched that `marked` carries and `other` has not seen:
    /// its epoch, when later than any `other` holds. That mark cleared the read
    /// stamp as well, so a stamp on `other`'s side from before it is one the
    /// mark took away.
    static func unwatchedEpoch(in marked: String?, unseenBy other: String?) -> Date? {
        guard let epoch = VideoWatchProgress(encoded: marked)?.unwatchedAt else { return nil }
        let seen = VideoWatchProgress(encoded: other)?.unwatchedAt ?? .distantPast
        return epoch > seen ? epoch : nil
    }

    /// Whether `locator` is a video's Mark as Not Watched with nothing played
    /// since: stored for its epoch, and not a position to resume or count as
    /// "in progress". Decodes only the locator that carries an epoch.
    static func isUnwatchedMarker(_ locator: String?) -> Bool {
        guard let locator, locator.contains(unwatchedAtKey),
              let progress = VideoWatchProgress(encoded: locator) else { return false }
        return !progress.recordsWatching
    }
}

// MARK: - The gate

/// Where one row of the path stands.
enum CourseStepState: Equatable {
    case open
    /// Watched, read, reviewed, or — for a quiz — completed.
    case finished
    /// Behind a quiz not yet completed; opens once `quizID` is.
    case locked(quizID: String)

    var lockingQuizID: String? {
        if case .locked(let quizID) = self { return quizID }
        return nil
    }
}

/// One row of a course's path as the gate reads it: its id, and the quiz it
/// is when it is one. The Mac's `CoursePathEntry` and the iPhone's
/// `MobileCoursePathRow` both are.
protocol CourseGateStep {
    var id: String { get }
    /// The quiz this row is, whose completed sitting opens what follows it; nil for a
    /// lecture, a reading or a material.
    var gatingQuizID: String? { get }
}

/// The gate over a course's path. Every written quiz holds back what comes
/// after it until the learner completes a sitting; its score and pass mark
/// remain feedback, not a progression trap. What was already finished stays
/// open, so going back over a lecture is never refused.
struct CourseGate {
    let states: [String: CourseStepState]
    /// The first quiz on the path not yet completed: the one that opens the rest.
    let blockingQuizID: String?
    /// The row Continue opens: the first on the path not yet finished that
    /// can be. It is never locked — anything locked sits behind an unfinished
    /// quiz, which comes first.
    let nextEntryID: String?
    /// Rows with no done state of their own and not reviewed either: a
    /// course's own PDF, a lesson or exercise sheet, which can be opened and
    /// reviewed but never watched or marked read. They carry no mark, are not
    /// counted, and Continue passes over them rather than waiting on them.
    let untrackedEntryIDs: Set<String>

    func state(of entry: some CourseGateStep) -> CourseStepState {
        states[entry.id] ?? .open
    }

    /// Whether the row can be done: counted in the page's progress, marked
    /// once done, and a stop for Continue.
    func tracksCompletion(of entry: some CourseGateStep) -> Bool {
        !untrackedEntryIDs.contains(entry.id)
    }

    /// Walks the path in order. `isFinished` says whether a row is done — for
    /// a quiz, whether it has been completed — and `hasDoneState` whether it can
    /// be done at all.
    init<Step: CourseGateStep>(
        entries: [Step],
        isFinished: (Step) -> Bool,
        hasDoneState: (Step) -> Bool = { _ in true }
    ) {
        var states: [String: CourseStepState] = [:]
        var blockingQuizID: String?
        var nextEntryID: String?
        var untracked: Set<String> = []
        for entry in entries {
            let finished = isFinished(entry)
            let tracked = finished || entry.gatingQuizID != nil || hasDoneState(entry)
            if !tracked { untracked.insert(entry.id) }
            if finished {
                states[entry.id] = .finished
            } else if let blockingQuizID {
                states[entry.id] = .locked(quizID: blockingQuizID)
            } else {
                states[entry.id] = .open
                if nextEntryID == nil, tracked { nextEntryID = entry.id }
                if let quizID = entry.gatingQuizID { blockingQuizID = quizID }
            }
        }
        self.states = states
        self.blockingQuizID = blockingQuizID
        self.nextEntryID = nextEntryID
        self.untrackedEntryIDs = untracked
    }
}

// MARK: - Progress and the gate from the records (schema v2 §8d)

/// A course's progress and its gate for one member, computed from the course's records and the
/// member's own, and never stored (schema v2 §8d, P8): the path from the Lessons, their item Entries
/// and the Quizzes; what is done from the member's ReadingStates and Sittings. The same on the Mac,
/// the iPhone and the web, so every surface shows one gate.
enum CourseProgressFold {
    /// A lesson on the path, by its fractional key.
    struct Lesson: Equatable, Sendable {
        let id: String
        let orderKey: String
    }

    /// A lesson's item: a source, or a part of one (`span`). `required` false leaves it out of the
    /// count (the Entry's `required`, true when absent).
    struct Item: Equatable, Sendable {
        let id: String
        let lessonID: String
        let orderKey: String
        let sourceID: String
        var span: Span? = nil
        var required: Bool = true
    }

    /// A span in the source's own units: 0-based PDF pages, or media seconds.
    enum Span: Equatable, Sendable {
        case pages(first: Int, last: Int)
        case seconds(from: Double, to: Double)
    }

    struct Quiz: Equatable, Sendable {
        let id: String
        /// The lesson it follows (`Quiz.lessonID`); nil ends the course.
        let lessonID: String?
        let kind: CourseQuiz.Kind
        let title: String
        let revision: Int
    }

    /// The member's ReadingState of a source, as the fold reads it, and the source's extent.
    struct Reading: Equatable, Sendable {
        var completed = false
        /// `furthest`: how far through the whole source, 0…1.
        var furthest: Double?
        var watchedSeconds: Double?
        /// The source's page count or media duration, to place `furthest` and a span.
        var pageCount: Int?
        var durationSeconds: Double?
    }

    /// One of the member's sittings of a quiz (`Sitting`, kind `courseQuiz`).
    struct Sitting: Equatable, Sendable {
        let quizID: String
        let quizRevision: Int?
        let right: Int
        let of: Int
        /// When it ended; a sitting not ended is not completed.
        let endedAt: Date?
    }

    /// The course's `policy`: whether quizzes gate, and the pass mark (`nil`: three in four).
    struct Policy: Equatable, Sendable {
        var gateQuizzes = true
        var pass: (right: Int, of: Int)? = nil

        static func == (lhs: Policy, rhs: Policy) -> Bool {
            lhs.gateQuizzes == rhs.gateQuizzes && lhs.pass?.right == rhs.pass?.right && lhs.pass?.of == rhs.pass?.of
        }

        /// What a sitting of `total` questions needs right to pass.
        func rightNeeded(total: Int) -> Int {
            guard let pass, pass.of > 0 else { return LectureQuizScore.rightNeededToPass(total: total) }
            return (pass.right * total + pass.of - 1) / pass.of
        }
    }

    /// One row of the path, as the gate walks it.
    struct Step: CourseGateStep, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case item(Item)
            case quiz(Quiz)
        }

        let kind: Kind
        let gates: Bool

        var id: String {
            switch kind {
            case .item(let item): return item.id
            case .quiz(let quiz): return quiz.id
            }
        }

        var gatingQuizID: String? {
            guard gates, case .quiz(let quiz) = kind else { return nil }
            return quiz.id
        }
    }

    /// A quiz's standing for the member: its latest completed sitting, and whether any passed.
    struct QuizStanding: Equatable, Sendable {
        let right: Int
        let of: Int
        let passed: Bool
        /// Taken on earlier questions than the quiz holds now (`quizRevision < revision`).
        let previousVersion: Bool
    }

    struct Progress {
        let path: [Step]
        let gate: CourseGate
        let finished: Set<String>
        let quizzes: [String: QuizStanding]
        /// Tracked rows done, of those counted.
        let done: Int
        let total: Int
    }

    /// The path: lessons by key; in each its items by key, then the quizzes that follow it by kind
    /// and title (`CourseQuizPlanning.placements`); a quiz whose lesson is not on the path ends it.
    static func path(lessons: [Lesson], items: [Item], quizzes: [Quiz], policy: Policy = Policy()) -> [Step] {
        let ordered = lessons.sorted { ($0.orderKey, $0.id) < ($1.orderKey, $1.id) }
        let onPath = Set(ordered.map(\.id))
        func sorted(_ list: [Quiz]) -> [Quiz] {
            list.sorted { ($0.kind.placementOrder, $0.title, $0.id) < ($1.kind.placementOrder, $1.title, $1.id) }
        }
        var steps: [Step] = []
        for lesson in ordered {
            for item in items.filter({ $0.lessonID == lesson.id }).sorted(by: { ($0.orderKey, $0.id) < ($1.orderKey, $1.id) }) {
                steps.append(Step(kind: .item(item), gates: false))
            }
            for quiz in sorted(quizzes.filter { $0.lessonID == lesson.id }) {
                steps.append(Step(kind: .quiz(quiz), gates: policy.gateQuizzes))
            }
        }
        for quiz in sorted(quizzes.filter { $0.lessonID.map { !onPath.contains($0) } ?? true }) {
            steps.append(Step(kind: .quiz(quiz), gates: policy.gateQuizzes))
        }
        return steps
    }

    /// Whether the member has done an item: marked complete, read 90% into its span (or the whole
    /// source), or watched 90% of its span (or the whole video).
    static func isDone(_ item: Item, reading: Reading?) -> Bool {
        guard let reading else { return false }
        if reading.completed { return true }
        switch item.span {
        case .pages(let first, let last)?:
            guard let furthest = reading.furthest, let pages = reading.pageCount, pages > 0, last >= first else { return false }
            return furthest * Double(pages) >= Double(first) + 0.9 * Double(last - first + 1)
        case .seconds(let from, let to)?:
            guard let watched = reading.watchedSeconds, to > from else { return false }
            return watched >= from + 0.9 * (to - from)
        case nil:
            if let furthest = reading.furthest, furthest >= 0.9 { return true }
            if let watched = reading.watchedSeconds, let duration = reading.durationSeconds, duration > 0 {
                return watched >= 0.9 * duration
            }
            return false
        }
    }

    /// A quiz's standing from the member's sittings of it: completed sittings only; passed by the
    /// earliest that reached the pass mark, kept through worse retakes (`LectureQuizScore.recorded`).
    static func standing(of quiz: Quiz, sittings: [Sitting], policy: Policy) -> QuizStanding? {
        let completed = sittings.filter { $0.quizID == quiz.id && $0.endedAt != nil && $0.of > 0 }
            .sorted { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
        guard let latest = completed.last else { return nil }
        return QuizStanding(
            right: latest.right, of: latest.of,
            passed: completed.contains { $0.right >= policy.rightNeeded(total: $0.of) },
            previousVersion: (latest.quizRevision ?? quiz.revision) < quiz.revision
        )
    }

    /// The course's progress for the member.
    static func progress(
        lessons: [Lesson], items: [Item], quizzes: [Quiz], policy: Policy = Policy(),
        readings: [String: Reading], sittings: [Sitting]
    ) -> Progress {
        let steps = path(lessons: lessons, items: items, quizzes: quizzes, policy: policy)
        var standings: [String: QuizStanding] = [:]
        var finished: Set<String> = []
        for step in steps {
            switch step.kind {
            case .item(let item):
                if isDone(item, reading: readings[item.sourceID]) { finished.insert(item.id) }
            case .quiz(let quiz):
                // A quiz is done once a sitting of it is completed, whatever it scored.
                if let standing = standing(of: quiz, sittings: sittings, policy: policy) {
                    standings[quiz.id] = standing
                    finished.insert(quiz.id)
                }
            }
        }
        let gate = CourseGate(entries: steps, isFinished: { finished.contains($0.id) }) { step in
            if case .item(let item) = step.kind { return item.required }
            return true
        }
        let counted = steps.filter { gate.tracksCompletion(of: $0) }
        return Progress(
            path: steps, gate: gate, finished: finished, quizzes: standings,
            done: counted.filter { finished.contains($0.id) }.count, total: counted.count
        )
    }
}
