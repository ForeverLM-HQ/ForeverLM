import Foundation

/// A course quiz taken in the chat (docs/lecture-quiz-design.md, "Taking a
/// quiz"). The product owner, 2026-09-26: "a quiz should just be implemented as part of
/// the chat", and "I shouldn't be let off the hook: I have to just give the
/// answer myself".
///
/// The tutor asks the stored questions in order and the learner answers in the
/// ordinary composer, dictation and pictures included. The tutor never grades:
/// it hands each answer to `grade_quiz_answer`, which runs the quiz's grader
/// and keeps the attempt in Memory, and only then learns the reference
/// answer. The grader is a call of its own on the chat's own model (product owner,
/// 2026-09-27: "the grading should really happen dynamically in the chat"),
/// so the model the learner chose for the chat grades it, and the tutor still
/// never reads an answer early. There is no Show answer; "I don't know" is an
/// answer, graded like any other. A first answer on the right track but short
/// of what the question asks gets one follow-up from the grader before any
/// grade, and the reply is graded with it.
///
/// A question can be skipped (product owner, 2026-09-27: "please do allow me to
/// skip questions in a quiz too"), by Skip Question under the tutor's reply
/// or by asking in words, which the tutor passes to `skip_quiz_question`. A
/// skip gives no grade and keeps nothing in Memory, the question counts as not
/// right in the score, so skipping never passes a quiz, and its answer is not
/// shown, so a retake still asks it.

/// What the Chat panel needs to open a quiz: the quiz, the lecture sources to
/// attach, and the view model's grader and score keeper, which already know
/// the lecture's numbered lines and the learner's Memory.
struct CourseQuizChatRequest {
    let quiz: CourseQuiz
    /// "Quiz: Cristae and Supercomplexes", the chat's title.
    let topic: String
    /// The lecture, the lectures covered, or the course.
    let subtitle: String
    /// The lecture sources the questions rest on, in course order.
    let sourceIDs: [String]
    /// Titles of those sources, for the question list.
    let sourceTitles: [String: String]
    /// The textbook readings planned for the quiz's lectures, in course
    /// order; empty when the course reads no book.
    var readings: [CourseQuizReading] = []
    /// Grades an attempt on `grader`, the chat's own model
    /// (`CourseQuizChatState.graderConfig(forChat:)`), keeping it in Memory,
    /// or returns the grader's follow-up with nothing kept.
    let grade: @MainActor (_ question: CourseQuizQuestion, _ attempt: QuizAnswerAttempt, _ grader: AITaskConfig) async throws -> (result: QuizGraderResult, memoryError: String?)
    /// After every grade: the chat's session, how far the sitting has got,
    /// and, once the last question is graded, the sitting's score.
    let recorded: @MainActor (_ sessionID: String, _ progress: CourseQuizSittingProgress) -> Void
}

/// A textbook reading planned for one of the quiz's lectures
/// (docs/textbook-readings-design.md). The product owner, 2026-09-27: during a quiz the
/// tutor should find the relevant chapters, and "planned readings should also
/// be able to be summarized in the chat". The pages are the plan's, never the
/// tutor's pick: `read_planned_reading` names a reading by its number and gets
/// exactly its pages.
struct CourseQuizReading: Equatable, Sendable {
    /// The lecture's own sources (its video, notes, slides): a question on
    /// any of them has this reading.
    let lectureSourceIDs: Set<String>
    /// "Lecture 8, Mitochondrial Ion Transport 1".
    let lectureTitle: String
    let chapterID: String
    let chapterTitle: String
    let bookTitle: String?
    /// The sections the pages hold, as the book titles them.
    let sections: String
    /// One-based pages within the chapter; nil reads it whole.
    let pages: ClosedRange<Int>?
    /// Why this learner reads it there, as the plan said.
    let reason: String?

    /// "Bioenergetics 4, 8 Transporters, pages 2–8", where it is in the book.
    var place: String {
        var text = [bookTitle, chapterTitle].compactMap { $0 }.joined(separator: ", ")
        if let pages {
            text += pages.count == 1 ? ", page \(pages.lowerBound)" : ", pages \(pages.lowerBound)–\(pages.upperBound)"
        }
        return text
    }

    /// Opens the chapter in the Reader at the reading's first page.
    var link: String {
        let page = pages.map { "?page=\($0.lowerBound)" } ?? ""
        return "[\(Self.linkText(sections))](foreverlm://source/\(chapterID)\(page))"
    }

    private static func linkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// The reading's pages from the chapter's stored text, marked `[page N]`
    /// at its page breaks (`TextbookOutline.pageTexts`); the whole text when
    /// the reading is the whole chapter. Nil when none of its pages have text.
    static func text(of pages: ClosedRange<Int>?, in content: String) -> String? {
        guard let pages else {
            let whole = PDFPageMarkers.labeled(content).trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? nil : whole
        }
        let byPage = TextbookOutline.pageTexts(content)
        let kept = pages.compactMap { page in byPage[page].map { "[page \(page)]\n\($0)" } }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// How far a sitting has got, as the quiz's row shows it.
struct CourseQuizSittingProgress: Equatable, Sendable {
    let sessionID: String
    /// Questions graded or skipped.
    let done: Int
    let total: Int
    /// Set once every question has been graded or skipped.
    let score: LectureQuizScore?

    var isFinished: Bool { score != nil }
    /// At least one question graded or skipped. A sitting opened and left on
    /// question 1 is not under way: its row keeps the last score, as Khan
    /// Academy's does (product owner, 2026-09-27, of a finished quiz that read "In
    /// progress · 0 of 4" after one click).
    var isUnderWay: Bool { !isFinished && done > 0 }
}

/// Which chat a click on a quiz opens (docs/lecture-quiz-design.md, "Taking a
/// quiz"), or nil for a new sitting on question 1. Like Khan Academy's: a
/// quiz under way is picked back up; a finished one opens its results, the
/// finished chat; a retake starts over. A sitting still on question 1 is
/// reused rather than left beside a new one.
enum CourseQuizOpening {
    static func chatToOpen(
        latest: CourseQuizSittingProgress?,
        lastFinished: CourseQuizSittingProgress?,
        retake: Bool,
        chatExists: (String) -> Bool
    ) -> String? {
        let open = latest.flatMap { !$0.isFinished && chatExists($0.sessionID) ? $0 : nil }
        if !retake {
            if let open, open.isUnderWay { return open.sessionID }
            if let lastFinished, chatExists(lastFinished.sessionID) { return lastFinished.sessionID }
        }
        if let open, !open.isUnderWay { return open.sessionID }
        return nil
    }
}

/// A quiz sitting as it is kept with its chat, so a quiz closed halfway is
/// picked up where it stopped, on this Mac or another (product owner, 2026-09-26:
/// "I do actually want to be able to pick them back up").
///
/// The chat's id names its quiz (`course-quiz-<quizID>-<UUID>`), so a
/// reopened chat knows what it is before anything is read; the grades ride
/// the session row's `briefing`, the column a memory review keeps its plan
/// in, which syncs inside the ReviewSession record. Each grade keeps the
/// question's words too: a quiz rewritten since keeps only the grades whose
/// question is still the one at that id. So does a follow-up waiting for its
/// reply, which a build without follow-ups reads past, and so does each skip,
/// which a build without skips reads as a question still to ask.
struct CourseQuizSitting: Codable, Equatable, Sendable {
    struct Grade: Codable, Equatable, Sendable {
        let verdict: VideoQuizVerdict
        let question: String
    }

    /// The grader's follow-up on the current first-pass question or correction
    /// and the answer it followed, until the reply is graded with that answer.
    struct FollowUp: Codable, Equatable, Sendable {
        let questionID: String
        /// The question's words, as a grade keeps them.
        let question: String
        let answer: String
        let followUp: String

        enum CodingKeys: String, CodingKey {
            case questionID = "question_id"
            case question, answer
            case followUp = "follow_up"
        }
    }

    let quizID: String
    /// By question id.
    var grades: [String: Grade]
    var followUp: FollowUp?
    /// The questions skipped, by id, each with its words; nil when none was,
    /// so a sitting without skips is kept exactly as before them.
    var skipped: [String: String]?

    enum CodingKeys: String, CodingKey {
        case quizID = "quiz_id"
        case grades
        case followUp = "follow_up"
        case skipped
    }

    static let sessionIDPrefix = "course-quiz-"

    /// A new chat's id for a sitting of this quiz.
    static func sessionID(forQuizID quizID: String, uuid: UUID = UUID()) -> String {
        sessionIDPrefix + quizID + "-" + uuid.uuidString
    }

    /// The quiz a chat is a sitting of, read from its id; nil for any other chat.
    static func quizID(inSessionID sessionID: String) -> String? {
        guard sessionID.hasPrefix(sessionIDPrefix) else { return nil }
        let rest = sessionID.dropFirst(sessionIDPrefix.count)
        let uuidLength = 36
        guard rest.count > uuidLength + 1,
              UUID(uuidString: String(rest.suffix(uuidLength))) != nil,
              rest.dropLast(uuidLength).last == "-" else { return nil }
        let quizID = String(rest.dropLast(uuidLength + 1))
        return quizID.isEmpty ? nil : quizID
    }

    private struct Envelope: Codable {
        let courseQuizSitting: CourseQuizSitting
        enum CodingKeys: String, CodingKey { case courseQuizSitting = "course_quiz_sitting" }
    }

    /// The sitting as the session row keeps it.
    var briefingText: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(courseQuizSitting: self)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A sitting read back from its session row; nil when the row holds none.
    init?(briefing: String?) {
        guard let data = briefing?.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        self = envelope.courseQuizSitting
    }

    init(quizID: String, grades: [String: Grade] = [:], followUp: FollowUp? = nil, skipped: [String: String]? = nil) {
        self.quizID = quizID
        self.grades = grades
        self.followUp = followUp
        self.skipped = skipped
    }

    /// The grades that still belong to this quiz's questions.
    func verdicts(for quiz: CourseQuiz) -> [String: VideoQuizVerdict] {
        var verdicts: [String: VideoQuizVerdict] = [:]
        for question in quiz.questions {
            guard let grade = grades[question.id], grade.question == question.question else { continue }
            verdicts[question.id] = grade.verdict
        }
        return verdicts
    }

    /// Whether reopening this chat can continue the current quiz rather than
    /// replaying a wholly superseded sitting. A rewrite may keep some exact
    /// questions, whose grades remain useful, but a sitting with grades and no
    /// matching question is history—not a fresh current sitting. The same is
    /// true of a pending follow-up whose question was rewritten, and of a
    /// sitting whose skips all belong to rewritten questions.
    func canResume(in quiz: CourseQuiz) -> Bool {
        guard quizID == quiz.id else { return false }
        let hasRecords = !grades.isEmpty || !(skipped ?? [:]).isEmpty
        if hasRecords && verdicts(for: quiz).isEmpty && skips(for: quiz).isEmpty { return false }
        guard let followUp else { return true }
        return quiz.questions.contains {
            $0.id == followUp.questionID && $0.question == followUp.question
        }
    }

    /// The skips that still belong to this quiz's questions; a question with
    /// a grade as well counts as graded.
    func skips(for quiz: CourseQuiz) -> Set<String> {
        guard let skipped else { return [] }
        let verdicts = verdicts(for: quiz)
        return Set(quiz.questions.filter { skipped[$0.id] == $0.question && verdicts[$0.id] == nil }.map(\.id))
    }

    func progress(for quiz: CourseQuiz, sessionID: String, takenAt: Date) -> CourseQuizSittingProgress {
        let verdicts = verdicts(for: quiz)
        let done = verdicts.count + skips(for: quiz).count
        let finished = !quiz.questions.isEmpty && done == quiz.questions.count
        return CourseQuizSittingProgress(
            sessionID: sessionID,
            done: done,
            total: quiz.questions.count,
            score: finished
                ? LectureQuizScore(
                    right: verdicts.values.filter { $0 == .correct }.count,
                    total: quiz.questions.count,
                    takenAt: takenAt
                )
                : nil
        )
    }

    /// Each quiz's newest sitting, from the session rows newest first. A row
    /// whose quiz is gone, or that holds no sitting, is passed over.
    static func latest(
        rows: [(sessionID: String, startedAt: Date, briefing: String?)],
        quizzes: [CourseQuiz]
    ) -> [String: CourseQuizSittingProgress] {
        let quizzesByID = Dictionary(quizzes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latest: [String: CourseQuizSittingProgress] = [:]
        for row in rows.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let quizID = quizID(inSessionID: row.sessionID), latest[quizID] == nil,
                  let quiz = quizzesByID[quizID],
                  let sitting = CourseQuizSitting(briefing: row.briefing),
                  sitting.quizID == quizID, sitting.canResume(in: quiz) else { continue }
            latest[quizID] = sitting.progress(for: quiz, sessionID: row.sessionID, takenAt: row.startedAt)
        }
        return latest
    }

    /// Each quiz's newest finished sitting, whose chat holds the results a
    /// click on a finished quiz opens.
    static func latestFinished(
        rows: [(sessionID: String, startedAt: Date, briefing: String?)],
        quizzes: [CourseQuiz]
    ) -> [String: CourseQuizSittingProgress] {
        let quizzesByID = Dictionary(quizzes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var finished: [String: CourseQuizSittingProgress] = [:]
        for row in rows.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let quizID = quizID(inSessionID: row.sessionID), finished[quizID] == nil,
                  let quiz = quizzesByID[quizID],
                  let sitting = CourseQuizSitting(briefing: row.briefing),
                  sitting.quizID == quizID, sitting.canResume(in: quiz) else { continue }
            let progress = sitting.progress(for: quiz, sessionID: row.sessionID, takenAt: row.startedAt)
            if progress.isFinished { finished[quizID] = progress }
        }
        return finished
    }
}

/// A quiz in progress in one chat: which questions have been graded, and how,
/// and which the learner skipped.
struct CourseQuizChatState {
    static let gradeToolName = "grade_quiz_answer"
    static let skipToolName = "skip_quiz_question"

    let request: CourseQuizChatRequest
    private(set) var verdicts: [String: VideoQuizVerdict] = [:]
    /// Questions the learner skipped, by id: no grade, nothing in Memory.
    private(set) var skipped: Set<String> = []
    /// The grader's follow-up on the question the quiz is on, while the
    /// learner replies to it.
    private(set) var followUp: CourseQuizSitting.FollowUp?

    /// A new sitting, or one picked up again with the grades and skips it
    /// already has and a follow-up still waiting for its reply.
    init(request: CourseQuizChatRequest, resuming sitting: CourseQuizSitting? = nil) {
        self.request = request
        if let sitting, sitting.quizID == request.quiz.id {
            verdicts = sitting.verdicts(for: request.quiz)
            skipped = sitting.skips(for: request.quiz)
            if let pending = sitting.followUp,
               let index = questions.firstIndex(where: { $0.id == pending.questionID }),
               questions[index].question == pending.question,
               currentIndex == index || (currentIndex == nil && verdicts[pending.questionID] != .correct) {
                followUp = pending
            }
        }
    }

    var questions: [CourseQuizQuestion] { request.quiz.questions }

    /// The grades and skips so far, as the chat's session row keeps them.
    var sitting: CourseQuizSitting {
        var grades: [String: CourseQuizSitting.Grade] = [:]
        var skips: [String: String] = [:]
        for question in questions {
            if let verdict = verdicts[question.id] {
                grades[question.id] = CourseQuizSitting.Grade(verdict: verdict, question: question.question)
            } else if skipped.contains(question.id) {
                skips[question.id] = question.question
            }
        }
        return CourseQuizSitting(
            quizID: request.quiz.id,
            grades: grades,
            followUp: followUp,
            skipped: skips.isEmpty ? nil : skips
        )
    }

    func progress(sessionID: String) -> CourseQuizSittingProgress {
        CourseQuizSittingProgress(
            sessionID: sessionID,
            done: verdicts.count + skipped.count,
            total: questions.count,
            score: isFinished ? score : nil
        )
    }

    /// Where the sitting stands, for the prompt's per-turn tail: after a
    /// reopened chat the transcript alone does not say which question is due.
    var progressNote: String {
        if let followUp,
           let index = questions.firstIndex(where: { $0.id == followUp.questionID }) {
            let context = currentIndex == nil
                ? "The completed quiz is revisiting question \(index + 1)"
                : "The quiz is on question \(index + 1)"
            let rule = currentIndex == nil ? "" : " " + openQuestionRule(index)
            return "Quiz progress: \(context), and the grader has asked a follow-up on the learner's answer: \"\(followUp.followUp)\". Ask it if it has not been asked since, and grade the learner's reply to it as their answer to question \(index + 1).\(rule)"
        }
        guard let current = currentIndex else {
            let missed = questions.enumerated()
                .filter { verdicts[$0.element.id] != .correct }
                .map { String($0.offset + 1) }
            guard !missed.isEmpty else {
                return "Quiz progress: every question has been graded (\(score.label)); every question is fully right."
            }
            let settled = skipped.isEmpty ? "graded" : "graded or skipped"
            let skips = skipped.isEmpty ? "" : " Skipped by the learner: questions \(numbers(of: skipped))."
            return "Quiz progress: every question has been \(settled) (\(score.label)).\(skips) Questions \(missed.joined(separator: ", ")) are not fully right and may be corrected, a skipped one included. When the learner wants to revisit one, ask that stored question again exactly as written, then grade their revised answer with \(Self.gradeToolName); each correction updates the sitting's score."
        }
        var lead = verdicts.isEmpty ? "No question has been graded yet." : "\(verdicts.count) of \(questions.count) questions graded."
        if !skipped.isEmpty {
            lead += " Skipped by the learner: questions \(numbers(of: skipped))."
        }
        return "Quiz progress: \(lead) The quiz is on question \(current + 1); ask it if it has not been asked since the last grade or skip, and grade only an answer to it. \(openQuestionRule(current))"
    }

    /// The rule `questionShownOutOfTurn` enforces, told to the tutor before
    /// it writes rather than only after a reply is withheld.
    private func openQuestionRule(_ open: Int) -> String {
        "Until \(Self.gradeToolName) or \(Self.skipToolName) returns for question \(open + 1), never say whether an answer is right, never give its answer, and never show another question: ForeverLM withholds a reply that does."
    }

    /// The number of a question a tutor reply shows that the sitting has not
    /// reached: one not yet graded or skipped, other than the question waiting
    /// for an answer. The product owner, 2026-09-28, of a sitting whose tutor, on a
    /// flash model, never called the grader for question 6: it judged the
    /// answer itself, gave the answer with a picture it made up and asked
    /// question 7, while the sitting stayed on question 6 and graded the next
    /// answer against it. "it thinks i'm on the wrong question", and "this
    /// should never be allowed to happen". The sitting says which question is
    /// open, not the tutor's words, so a reply that goes past it is withheld
    /// (`ReviewSessionManager`). A question counts as shown by its heading,
    /// `Question 7 of 20` at the start of a line as `heading(forQuestionAt:)`
    /// writes it, or by its stored words. Nil when the reply keeps to the
    /// sitting, and when no question is waiting: once every question is
    /// settled, any may be revisited.
    func questionShownOutOfTurn(in reply: String) -> Int? {
        guard let current = currentIndex else { return nil }
        let unreached = questions.indices.filter { index in
            let id = questions[index].id
            return index != current && verdicts[id] == nil && !skipped.contains(id)
        }
        guard !unreached.isEmpty else { return nil }
        let headed = Self.headedQuestionNumbers(in: reply, total: questions.count)
        let replyWords = " " + Self.words(in: reply).joined(separator: " ") + " "
        for index in unreached {
            if headed.contains(index + 1) { return index + 1 }
            let words = Self.words(in: questions[index].question)
            // A short question's words could turn up in a sentence about
            // something else; its heading still gives it away.
            guard words.count >= Self.shownQuestionMinimumWords else { continue }
            if replyWords.contains(" " + words.joined(separator: " ") + " ") { return index + 1 }
        }
        return nil
    }

    /// Questions of fewer words are matched by their heading only.
    static let shownQuestionMinimumWords = 5

    /// The numbers under `Question N of <total>` headings, each at the start
    /// of a line, bold, a Markdown heading or a quote as it may be.
    static func headedQuestionNumbers(in text: String, total: Int) -> Set<Int> {
        guard let expression = try? NSRegularExpression(
            pattern: #"^[ \t>]*(?:#{1,6}[ \t]+)?(?:\*\*|__)?[ \t]*Question[ \t]+(\d+)[ \t]+of[ \t]+(\d+)\b"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var numbers: Set<Int> = []
        for match in expression.matches(in: text, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let totalRange = Range(match.range(at: 2), in: text),
                  Int(text[totalRange]) == total,
                  let number = Int(text[numberRange]) else { continue }
            numbers.insert(number)
        }
        return numbers
    }

    /// Lowercased runs of letters and digits, so Markdown, punctuation and
    /// line breaks do not hide a question copied into a reply.
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// What the tutor is told when its reply showed question `shown` while
    /// the sitting is on another: the reply was withheld, nothing was graded,
    /// and what to do instead.
    func outOfTurnCorrection(shown: Int) -> String {
        guard let current = currentIndex else { return "" }
        let open = current + 1
        let waiting = pendingFollowUp(at: current) == nil
            ? "the quiz is on question \(open), which has no grade"
            : "question \(open) is still waiting for the learner's reply to the grader's follow-up, and has no grade"
        let answer = pendingFollowUp(at: current) == nil
            ? "If the learner's last message answers question \(open), call \(Self.gradeToolName) now with question \(open) and their words as they wrote them"
            : "If the learner's last message replies to the follow-up, call \(Self.gradeToolName) now with question \(open) and their reply as they wrote it"
        return [
            "ForeverLM withheld that reply, and the learner has not seen it: it showed question \(shown), but \(waiting). Nothing was checked or kept.",
            "\(answer), and reply from its result. If they asked to skip it, call \(Self.skipToolName). If they asked something instead of answering, answer that and ask question \(open) again.",
            "Never judge an answer yourself, give its answer, or show another question before one of those tools has returned.",
        ].joined(separator: " ")
    }

    /// What the learner is told when the tutor kept going past the open
    /// question after being told: nothing was graded, and how to go on.
    func outOfTurnFailure(shown: Int) -> String {
        guard let current = currentIndex else { return "" }
        let open = current + 1
        return "The tutor went on to question \(shown) while question \(open) was still waiting for its grade, so its reply was not shown and nothing was graded or kept. Send your answer to question \(open) again, or switch this chat to another model with the model chip under the message box."
    }

    /// "2, 5", the numbers of these questions in quiz order.
    private func numbers(of ids: Set<String>) -> String {
        questions.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { "\($0.offset + 1)" }
            .joined(separator: ", ")
    }

    /// The follow-up waiting on the question at `index`, if any.
    private func pendingFollowUp(at index: Int) -> CourseQuizSitting.FollowUp? {
        guard let followUp, followUp.questionID == questions[index].id else { return nil }
        return followUp
    }

    /// The question waiting for an answer, or nil once every one is graded
    /// or skipped.
    var currentIndex: Int? {
        questions.firstIndex { verdicts[$0.id] == nil && !skipped.contains($0.id) }
    }

    var isFinished: Bool { currentIndex == nil }

    var score: LectureQuizScore {
        LectureQuizScore(
            right: questions.filter { verdicts[$0.id] == .correct }.count,
            total: questions.count,
            takenAt: Date()
        )
    }

    /// The hidden first turn: the learner asks for the quiz to begin.
    var openingRequest: String {
        "Start the quiz: ask question 1."
    }

    /// The quiz's first message, written by the app from the stored quiz so
    /// it is on screen the moment the quiz opens (product owner, 2026-09-27: "when
    /// i click a quiz, i want it to be ALREADY generated"): one line naming
    /// the quiz and its length, then question 1 under its heading.
    var openingMessage: String {
        let count = "\(questions.count) question\(questions.count == 1 ? "" : "s")"
        guard let first = questions.first else { return "\(request.topic) · \(count)" }
        let picture = pictureLine(for: first, shownWith: .question).map { "\n\n" + $0 } ?? ""
        return "\(request.topic) · \(count)\n\n\(heading(forQuestionAt: 0))\(picture)\n\n\(first.question)"
    }

    /// The Markdown image line of the picture a question is shown with at
    /// this point of the sitting, or nil when it has none there.
    func pictureLine(for question: CourseQuizQuestion, shownWith placement: CourseQuizPicture.Placement) -> String? {
        guard let picture = question.picture, picture.placement == placement else { return nil }
        guard picture.reference != nil else {
            // A picture drawn for the question or kept from another app: its
            // caption, else the brief's opening, never a source's title.
            return picture.markdown(fallbackAlt: picture.brief.map { Self.shortAlt($0) } ?? "A picture for this question")
        }
        var alt = question.sourceID.flatMap { request.sourceTitles[$0] } ?? "The lecture"
        switch picture.reference?.location {
        case .moment(let seconds)?:
            alt += " at \(VideoQuizPlanning.timestamp(Double(seconds)))"
        case .page(let page)?:
            alt += ", page \(page)"
        default:
            break
        }
        return picture.markdown(fallbackAlt: alt)
    }

    /// What the picture a question is shown with at this point of the
    /// sitting shows, as its line's alt text says it; nil when it has none
    /// there. The tutor is told this, never the address.
    func pictureAlt(for question: CourseQuizQuestion, shownWith placement: CourseQuizPicture.Placement) -> String? {
        pictureLine(for: question, shownWith: placement).flatMap(Self.alt(ofPictureLine:))
    }

    /// The alt text of a Markdown image line.
    private static func alt(ofPictureLine line: String) -> String? {
        guard let open = line.range(of: "!["),
              let close = line.range(of: "](", options: .backwards) else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }

    /// The stored quiz, not the tutor model, puts the quiz's pictures in a
    /// reply. The product owner, 2026-09-28, of "quality control escalation: picture
    /// unavailable on this device" under question 11: "should not be allowed
    /// to happen! fix it at its root". The tutor was handed each stored
    /// picture's line to copy, and on GLM 5.3 Flash, in the three replies
    /// where it skipped the grader, it wrote lines of the same shape with ids
    /// it made up. Every stored picture of this quiz in the reply is taken
    /// out, whoever wrote it and wherever it stands. Then each question the
    /// reply asks gets its own picture between its heading and its words,
    /// and the answered question's `answerBlock` takes the place of the
    /// tutor's own link to that question's lecture or reading, if it wrote
    /// one before the next question, or else goes before the block of the
    /// next question the reply asks, or at its end. A rule then sets the
    /// next question apart from what came before it, so the feedback's
    /// picture never reads as the next question's. A question counts as
    /// asked when its stored words open a line.
    func placingPictures(in reply: String, answeredQuestionIndex: Int?, isCorrection: Bool = false) -> String {
        let stored = Set(questions.compactMap(\.picture).flatMap { picture in
            [picture.image, picture.reference?.urlString].compactMap { $0?.lowercased() }
        })
        var result = SourceImageReference.removingPictures(from: reply) { stored.contains($0.lowercased()) }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let asked = questions.indices
            .filter { $0 != answeredQuestionIndex }
            .compactMap { index in askedRange(ofQuestionAt: index, in: result).map { (index, $0) } }
            .sorted { $0.1.lowerBound > $1.1.lowerBound }
        // `asked` runs from the end of the reply, so its last is the first.
        let firstAsked = asked.last?.0
        let nextBlockStart: (String) -> String.Index? = { text in
            firstAsked.flatMap { index in
                self.askedRange(ofQuestionAt: index, in: text).map { self.blockStart(ofQuestionAt: index, askedAt: $0, in: text) }
            }
        }

        for (index, _) in asked {
            guard let line = pictureLine(for: questions[index], shownWith: .question),
                  let range = askedRange(ofQuestionAt: index, in: result) else { continue }
            result = Self.inserting(line, at: range.lowerBound, in: result)
        }

        if let answeredQuestionIndex,
           questions.indices.contains(answeredQuestionIndex),
           let block = answerBlock(forQuestionAt: answeredQuestionIndex, isCorrection: isCorrection) {
            // Only a link to this question's own place is the tutor's
            // rewatch link: a planned reading's link to the same chapter,
            // or the sitting's result pointing into the lecture, stays.
            let question = questions[answeredQuestionIndex]
            let place = placeLink(for: question).flatMap(Self.linkTarget)
            if let sourceID = question.sourceID, let place,
               let own = Self.standaloneLinkLines(toSource: sourceID, in: result, before: nextBlockStart(result) ?? result.endIndex)
                   .first(where: { Self.linkTarget(String(result[$0])) == place }) {
                result.replaceSubrange(own, with: block)
            } else {
                result = nextBlockStart(result).map { Self.inserting(block, at: $0, in: result) } ?? result + "\n\n" + block
            }
        }

        if let start = nextBlockStart(result) {
            let head = result[..<start]
                .replacingOccurrences(of: #"(?:\n|^)[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if !head.isEmpty {
                result = [head, "---", String(result[start...])].joined(separator: "\n\n")
            }
        }
        return result
    }

    /// The picture ForeverLM shows with the feedback on the question at
    /// `index`, or nil when it has none, or when the learner already has it
    /// in front of them: the feedback just before, on the question before
    /// this one, showed this very picture, or the next question shows it
    /// above its words. The product owner, 2026-09-28, of question 17 of "Biogenesis,
    /// Quality, and Signaling", whose feedback showed again the slide the
    /// feedback on question 16 had just shown: "it kind of shows this kind
    /// of random slide from the video". A correction comes long after the
    /// question before it, so it shows its picture.
    func answerPictureLine(forQuestionAt index: Int, isCorrection: Bool = false) -> String? {
        let question = questions[index]
        guard let line = pictureLine(for: question, shownWith: .answer) else { return nil }
        guard !isCorrection, let image = question.picture?.image.lowercased() else { return line }
        let shows: (CourseQuizQuestion, CourseQuizPicture.Placement) -> Bool = { other, placement in
            other.picture?.placement == placement && other.picture?.image.lowercased() == image
        }
        if index > 0, verdicts[questions[index - 1].id] != nil, shows(questions[index - 1], .answer) {
            return nil
        }
        if let next = currentIndex, next != index, shows(questions[next], .question) {
            return nil
        }
        return line
    }

    /// The link to where the lecture or reading gives the question's answer:
    /// `[Rewatch 12:34](foreverlm://source/<lecture>?t=754)` for a moment of a
    /// lecture, `[Reread page 5](…)` for a page of a reading; nil when the
    /// question has neither.
    func placeLink(for question: CourseQuizQuestion) -> String? {
        if let sourceID = question.sourceID, let seconds = question.startSeconds {
            let time = VideoQuizPlanning.timestamp(seconds)
            return "[Rewatch \(time)](foreverlm://source/\(sourceID)?t=\(Int(seconds.rounded(.down))))"
        }
        return rereadLink(for: question)
    }

    /// Where `placeLink` goes, as the tutor is told it: "Lecture 3 at 12:34",
    /// "page 5 of Chapter 8".
    private func placeName(for question: CourseQuizQuestion) -> String? {
        guard let sourceID = question.sourceID else { return nil }
        let title = request.sourceTitles[sourceID]
        if let seconds = question.startSeconds {
            return "\(title ?? "the lecture") at \(VideoQuizPlanning.timestamp(seconds))"
        }
        guard let page = question.page else { return nil }
        return "page \(page) of \(title ?? "the reading")"
    }

    /// What ForeverLM shows under the tutor's feedback on the question at
    /// `index`: the picture for the answer with the link to its place in the
    /// lecture or reading on the line after it, which the chat draws as the
    /// picture's caption when the picture comes from that same source; the
    /// link alone when the answer was missed and no picture shows. Nil when
    /// there is neither. The link and the picture come as one block: a link
    /// and a picture written separately would show a card for the video, then
    /// a slide with nothing to say it came from that video.
    func answerBlock(forQuestionAt index: Int, isCorrection: Bool = false) -> String? {
        let question = questions[index]
        let picture = answerPictureLine(forQuestionAt: index, isCorrection: isCorrection)
        let missed = verdicts[question.id].map { $0 != .correct } ?? false
        let captions = picture != nil && question.picture?.reference?.sourceID == question.sourceID
        let link = missed || captions ? placeLink(for: question) : nil
        let lines = [picture, link].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// The ranges of the lines of `text` before `end` that are nothing but a
    /// link to the source, past any list mark or emphasis: the tutor's own
    /// rewatch or reread link among them, which ForeverLM writes instead.
    private static func standaloneLinkLines(toSource sourceID: String, in text: String, before end: String.Index) -> [Range<String.Index>] {
        let id = NSRegularExpression.escapedPattern(for: sourceID)
        guard let expression = try? NSRegularExpression(
            pattern: #"^[ \t]*(?:[-*+][ \t]+)?(?:\*\*|__|\*|_)?\[[^\]\n]*\]\(<?foreverlm://source/"# + id
                + #"(?:[?#][^)\s>]*)?>?(?:[ \t]+"[^"\n]*")?\)(?:\*\*|__|\*|_)?[ \t]*$"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else { return [] }
        let searched = NSRange(text.startIndex..<end, in: text)
        return expression.matches(in: text, range: searched).compactMap { Range($0.range, in: text) }
    }

    /// The `foreverlm://source/...` target of the first link in `line`,
    /// lowercased; nil when it has none.
    private static func linkTarget(_ line: String) -> String? {
        guard let open = line.range(of: "](") else { return nil }
        let target = line[open.upperBound...].prefix { !")> \t\"".contains($0) }
        let trimmed = target.hasPrefix("<") ? target.dropFirst() : target
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// Where the question's stored words open a line of `text`, past any
    /// indent, quote mark or emphasis; nil when they never do.
    private func askedRange(ofQuestionAt index: Int, in text: String) -> Range<String.Index>? {
        let words = questions[index].question
        guard !words.isEmpty else { return nil }
        var from = text.startIndex
        while let range = text.range(of: words, range: from..<text.endIndex) {
            let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            if text[lineStart..<range.lowerBound].allSatisfy({ " \t>*_".contains($0) }) { return range }
            from = range.upperBound
        }
        return nil
    }

    /// The start of the heading above an asked question, or of its words
    /// when it has none.
    private func blockStart(ofQuestionAt index: Int, askedAt range: Range<String.Index>, in text: String) -> String.Index {
        let prefix = text[..<range.lowerBound]
        for token in ["**Question \(index + 1)", "Question \(index + 1)"] {
            if let heading = prefix.range(of: token, options: .backwards) { return heading.lowerBound }
        }
        return range.lowerBound
    }

    /// `block` on lines of its own at `index`, one blank line either side.
    private static func inserting(_ block: String, at index: String.Index, in text: String) -> String {
        let head = text[..<index].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let tail = text[index...].replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        return [head, block, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The opening of a brief as alt text, cut at a word.
    private static func shortAlt(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 90 else { return flattened }
        let head = String(flattened.prefix(90))
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head[...]
        return String(cut).trimmingCharacters(in: .punctuationCharacters) + "…"
    }

    /// What the tutor is told about pictures for a question it is about to
    /// ask: what the stored picture ForeverLM shows above it shows, or, for a
    /// moment of a lecture video, where to look for one.
    private func questionPictureNote(for question: CourseQuizQuestion) -> String? {
        if let alt = pictureAlt(for: question, shownWith: .question) {
            return "ForeverLM shows this question's picture, \"\(alt)\", between its heading and its text: write no picture line for it."
        }
        guard question.picture?.isShowable != true, let sourceID = question.sourceID else { return nil }
        guard let seconds = question.startSeconds else {
            guard let page = question.page else { return nil }
            return "If the question is about a figure, table or equation on page \(page) of the reading, show it above the question with show_source_image (source_id \(sourceID), page \(page), cropped to the part that matters), unless it would give the answer away."
        }
        return "If the question is about something the lecture shows around \(VideoQuizPlanning.timestamp(seconds)) (a diagram, structure, graph or equation), show it above the question with show_source_image (source_id \(sourceID), at \(Int(seconds.rounded(.down))), cropped to the part that matters), unless it would give the answer away."
    }

    /// The quiz as the tutor reads it, fixed for the session so it stays in
    /// the cached head: the questions, their levels and where each is in the
    /// lectures. The reference answers are left out on purpose; the grader's
    /// result brings each one after the learner has answered.
    var questionList: String {
        let quiz = request.quiz
        let kind: String
        switch quiz.kind {
        case .practice: kind = "the practice quiz after a lecture"
        case .checkpoint: kind = "a checkpoint quiz across several lectures"
        case .test: kind = "the course test, across every lecture"
        }
        var lines = [
            "Quiz for this session: \"\(quiz.title)\", \(kind) (\(request.subtitle)), \(questions.count) question\(questions.count == 1 ? "" : "s").",
            "The reference answers are not given to you. \(Self.gradeToolName) returns each one after the learner has answered.",
            "",
        ]
        for (index, question) in questions.enumerated() {
            lines.append("\(index + 1). \(label(for: question)): \(question.question)")
            if let alt = pictureAlt(for: question, shownWith: .question) {
                lines.append("   ForeverLM shows it with its picture, \"\(alt)\", between the heading and the question.")
            } else if question.picture?.placement == .answer, question.picture?.isShowable == true {
                lines.append("   Has a picture for the answer, which ForeverLM shows with the feedback once it is graded.")
            }
        }
        if let readings = readingList {
            lines.append("")
            lines.append(readings)
        }
        return lines.joined(separator: "\n")
    }

    static let readingToolName = "read_planned_reading"

    /// The course's planned readings for these lectures, numbered as
    /// `read_planned_reading` takes them; nil when there are none.
    var readingList: String? {
        let readings = request.readings
        guard !readings.isEmpty else { return nil }
        var lines = [
            "Planned readings: the textbook sections the course plans for these lectures, chosen for this learner. \(Self.readingToolName) returns a reading's pages.",
        ]
        for (index, reading) in readings.enumerated() {
            var line = "R\(index + 1). With \(reading.lectureTitle): \(reading.sections) (\(reading.place)) · link \(reading.link)"
            if let reason = reading.reason { line += " · why: \(reason)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The readings a question goes with, by their numbers: those of the
    /// lecture it is on, or, for a question about a reading, the reading
    /// whose pages hold it.
    func readingNumbers(for question: CourseQuizQuestion) -> [Int] {
        guard let sourceID = question.sourceID else { return [] }
        return request.readings.indices.filter { index in
            let reading = request.readings[index]
            if reading.lectureSourceIDs.contains(sourceID) { return true }
            guard reading.chapterID == sourceID else { return false }
            guard let pages = reading.pages, let page = question.page else { return true }
            return pages.contains(page)
        }.map { $0 + 1 }
    }

    /// `[Reread page 5](foreverlm://source/<chapter>?page=5)`, for a question
    /// about a reading; nil for a lecture's.
    func rereadLink(for question: CourseQuizQuestion) -> String? {
        guard question.startSeconds == nil, let sourceID = question.sourceID, let page = question.page else { return nil }
        return "[Reread page \(page)](foreverlm://source/\(sourceID)?page=\(page))"
    }

    /// `[Recall · Lecture 3 at 12:34 · source_id abc · reading R2]`, what the
    /// tutor needs to head the question, show its slide and point to the book.
    private func label(for question: CourseQuizQuestion) -> String {
        var parts: [String] = []
        if let level = question.level { parts.append(level.displayName) }
        if let sourceID = question.sourceID {
            var place = request.sourceTitles[sourceID] ?? "the lecture"
            if let seconds = question.startSeconds {
                place += " at \(VideoQuizPlanning.timestamp(seconds))"
            } else if let page = question.page {
                place += " page \(page)"
            }
            parts.append(place)
            parts.append("source_id \(sourceID)")
        }
        let readings = readingNumbers(for: question)
        if !readings.isEmpty {
            parts.append((readings.count == 1 ? "reading " : "readings ") + readings.map { "R\($0)" }.joined(separator: ", "))
        }
        return "[" + parts.joined(separator: " · ") + "]"
    }

    /// `**Question 4 of 24 · Apply**`, the heading the tutor puts over a question.
    func heading(forQuestionAt index: Int) -> String {
        var heading = "Question \(index + 1) of \(questions.count)"
        if let level = questions[index].level { heading += " · \(level.displayName)" }
        return "**\(heading)**"
    }

    var toolSpec: AIToolSpec {
        AIToolSpec(
            name: Self.gradeToolName,
            description: "Grade the learner's answer to the quiz question they are on. During the initial sitting, call it as soon as the learner has attempted the current question — \"I don't know\" and guesses included — and never for a question they asked instead of answering. After every question has been graded, call it for a revised answer to any question that is not fully right; the correction replaces that question's verdict and updates the score. The quiz's grader judges the answer against the reference answer and the lecture, keeps the attempt in the learner's Memory, and returns the verdict, its feedback, the reference answer, where to rewatch, and what comes next. When a first answer is on the right track but short of what the question asks, it returns one follow-up question instead of a grade: ask it, then call this again with the learner's reply. Never tell the learner whether they are right before this returns.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "The number of the question being answered, from the quiz list."
                    ],
                    "answer": [
                        "type": "string",
                        "description": "The learner's answer exactly as they wrote or said it, joined across their messages if they answered in more than one; after a follow-up, their reply to it, since their first answer is kept. Never correct, complete or improve it."
                    ],
                ] as [String: Any],
                "required": ["question", "answer"],
            ]
        )
    }

    var skipToolSpec: AIToolSpec {
        AIToolSpec(
            name: Self.skipToolName,
            description: "Skip the quiz question the learner is on, when they ask to skip it or to move on without answering it, during a follow-up too. The question gets no grade and nothing in Memory, and it counts as not right in the score. Call it only when the learner asks: never on your own, never for an answer (\"I don't know\" and guesses go to grade_quiz_answer), and never to spare them a hard question. Returns the next question, or the quiz's result after the last one.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "The number of the question being skipped, from the quiz list: the one the quiz is on."
                    ],
                ] as [String: Any],
                "required": ["question"],
            ]
        )
    }

    /// `read_planned_reading`, offered only when the quiz's lectures have
    /// planned readings.
    var readingToolSpec: AIToolSpec? {
        guard !request.readings.isEmpty else { return nil }
        return AIToolSpec(
            name: Self.readingToolName,
            description: "Read one of the quiz's planned textbook readings: returns exactly the pages the course planned for it, from the chapter's text, marked [page N] within the chapter. Call it when the learner asks what a reading covers, asks for it summarized, or asks where the book explains something a question is about, and summarize or quote from what it returns. Never use it to hint at the answer to a question the learner has not answered yet.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "reading": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": request.readings.count,
                        "description": "The reading's number, R1 as 1, from the planned readings list."
                    ],
                ] as [String: Any],
                "required": ["reading"],
            ]
        )
    }

    /// The reading a `read_planned_reading` call names, or why not.
    func readingToRead(arguments: [String: Any]) -> Result<(number: Int, reading: CourseQuizReading), CourseQuizChatError> {
        let readings = request.readings
        guard !readings.isEmpty else {
            return .failure(CourseQuizChatError("This quiz's lectures have no planned readings."))
        }
        let raw = (arguments["reading"] as? NSNumber)?.intValue
            ?? (arguments["reading"] as? String).flatMap {
                Int($0.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "R", with: ""))
            }
        guard let number = raw, readings.indices.contains(number - 1) else {
            return .failure(CourseQuizChatError("Pass reading as a number from 1 to \(readings.count), R1 as 1."))
        }
        return .success((number, readings[number - 1]))
    }

    /// What the tutor gets back from a reading: where it is, why it was
    /// planned, and its pages.
    static func readingResult(number: Int, reading: CourseQuizReading, text: String) -> String {
        var lines = [
            "Planned reading R\(number): \(reading.sections)",
            "Where: \(reading.place). Open it with \(reading.link).",
            "Read with: \(reading.lectureTitle).",
        ]
        if let reason = reading.reason { lines.append("Why it was planned: \(reason)") }
        lines.append("")
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    /// The question a `grade_quiz_answer` call may grade and the attempt to
    /// grade, or why not. The first time through, only the question the quiz
    /// is on can be graded. Once all questions have a verdict, any question
    /// that is not fully right may be answered again to improve the sitting's
    /// score. The learner can reply in the chat, so a first answer may be
    /// followed up; after a follow-up, the call's answer is the reply, graded
    /// with the answer the follow-up was asked on.
    func questionToGrade(arguments: [String: Any]) -> Result<(index: Int, attempt: QuizAnswerAttempt), CourseQuizChatError> {
        let number = (arguments["question"] as? NSNumber)?.intValue
            ?? (arguments["question"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let number else {
            let expected = currentIndex.map { String($0 + 1) } ?? "from 1 to \(questions.count)"
            return .failure(CourseQuizChatError("Pass question as the question's number, \(expected)."))
        }
        guard questions.indices.contains(number - 1) else {
            return .failure(CourseQuizChatError(
                "Question \(number) is outside this quiz; pass a number from 1 to \(questions.count)."
            ))
        }
        let index = number - 1
        if let pending = followUp,
           let pendingIndex = questions.firstIndex(where: { $0.id == pending.questionID }),
           index != pendingIndex {
            return .failure(CourseQuizChatError(
                "Question \(pendingIndex + 1) is waiting for the learner's reply to its follow-up; grade that reply before another question."
            ))
        }
        if let current = currentIndex {
            guard index == current else {
                let id = questions[index].id
                let detail: String
                if verdicts[id] != nil {
                    detail = "Question \(number) has already been graded."
                } else if skipped.contains(id) {
                    detail = "Question \(number) was skipped; it can be answered once the quiz's last question is settled."
                } else {
                    detail = "Question \(number) is not the one the quiz is on."
                }
                return .failure(CourseQuizChatError(
                    "\(detail) The learner is on question \(current + 1); grade only an answer to it."
                ))
            }
        } else if verdicts[questions[index].id] == .correct {
            return .failure(CourseQuizChatError(
                "Question \(number) is already fully right. The learner may correct a question that is not fully right."
            ))
        }
        let answer = (arguments["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pending = pendingFollowUp(at: index)
        guard !answer.isEmpty else {
            return .failure(CourseQuizChatError(pending == nil
                ? "Pass the learner's answer, as they wrote it. If they have not answered question \(number) yet, ask it and wait."
                : "Pass the learner's reply to the follow-up, as they wrote it. If they have not replied yet, wait for it."
            ))
        }
        guard let asked = pending else {
            return .success((index, QuizAnswerAttempt(answer: answer, learnerCanReply: true)))
        }
        return .success((index, QuizAnswerAttempt(
            answer: asked.answer,
            followUp: QuizAnswerAttempt.FollowUp(question: asked.followUp, reply: answer),
            learnerCanReply: true
        )))
    }

    /// The question a `skip_quiz_question` call may skip, or why not: only
    /// the one the quiz is on, a follow-up waiting on it or not.
    func questionToSkip(arguments: [String: Any]) -> Result<Int, CourseQuizChatError> {
        currentQuestion(named: arguments, doing: "skip only it, and only when the learner asks")
    }

    /// The question a call names, when it is the one the quiz is on.
    private func currentQuestion(named arguments: [String: Any], doing action: String) -> Result<Int, CourseQuizChatError> {
        guard let current = currentIndex else {
            return .failure(CourseQuizChatError(
                "Every question of this quiz has been graded or skipped; there is nothing left to skip. Answer the learner in conversation."
            ))
        }
        let number = (arguments["question"] as? NSNumber)?.intValue
            ?? (arguments["question"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let number else {
            return .failure(CourseQuizChatError("Pass question as the question's number, \(current + 1)."))
        }
        guard number == current + 1 else {
            let id = questions.indices.contains(number - 1) ? questions[number - 1].id : nil
            let detail: String
            if let id, verdicts[id] != nil {
                detail = "Question \(number) has already been graded."
            } else if let id, skipped.contains(id) {
                detail = "Question \(number) was skipped."
            } else {
                detail = "Question \(number) is not the one the quiz is on."
            }
            return .failure(CourseQuizChatError(
                "\(detail) The learner is on question \(current + 1); \(action)."
            ))
        }
        return .success(current)
    }

    mutating func record(_ verdict: VideoQuizVerdict, forQuestionAt index: Int) {
        verdicts[questions[index].id] = verdict
        // A skipped question answered as a correction counts as graded.
        skipped.remove(questions[index].id)
        if followUp?.questionID == questions[index].id {
            followUp = nil
        }
    }

    /// Skips the question at `index`, and drops a follow-up waiting on it:
    /// the answer it followed is not graded.
    mutating func recordSkip(forQuestionAt index: Int) {
        let id = questions[index].id
        guard verdicts[id] == nil else { return }
        skipped.insert(id)
        if followUp?.questionID == id {
            followUp = nil
        }
    }

    /// Keeps the grader's follow-up on the question at `index`, with the
    /// answer it was asked on, until the reply is graded.
    mutating func recordFollowUp(_ followUp: String, answer: String, forQuestionAt index: Int) {
        let question = questions[index]
        self.followUp = CourseQuizSitting.FollowUp(
            questionID: question.id,
            question: question.question,
            answer: answer,
            followUp: followUp
        )
    }

    /// What the tutor learns when the grader asks a follow-up instead of
    /// grading: the follow-up, and that the reply finishes the answer. It
    /// carries no reference answer, since the question is not graded yet.
    func followUpRequest(forQuestionAt index: Int, followUp: String) -> String {
        let number = index + 1
        let status = verdicts[questions[index].id] == nil
            ? "Question \(number) of \(questions.count) is not graded yet"
            : "The correction to question \(number) of \(questions.count) is not graded yet; its previous verdict and score remain until the correction is graded"
        return [
            "\(status): the learner's answer is on the right track but does not yet have everything the question asks for.",
            "Follow-up: \(followUp)",
            "Now ask the learner this follow-up, as written, and nothing more: no verdict yet, no answer, and no hint that contains it. When they reply, call \(Self.gradeToolName) again with question \(number) and their reply as the answer; their first answer is kept and graded with it. There is no second follow-up: the next call gives the grade.",
        ].joined(separator: "\n")
    }

    /// What the tutor learns from a grade: the verdict, the grader's words,
    /// the reference answer, the moment to rewatch, and what comes next.
    func acknowledgement(
        forQuestionAt index: Int,
        grade: VideoQuizGrade,
        memoryError: String?,
        isCorrection: Bool = false
    ) -> String {
        let question = questions[index]
        let verdict: String
        switch grade.verdict {
        case .correct: verdict = "right"
        case .partial: verdict = "partly right"
        case .incorrect: verdict = "not right"
        }
        var lines = [
            "Question \(index + 1) of \(questions.count) graded: \(verdict).",
            "Grader's feedback: \(grade.feedback)",
            "Reference answer: \(question.answer)",
        ]
        if !question.keyPoints.isEmpty {
            lines.append("Key points: " + question.keyPoints.joined(separator: "; "))
        }
        // ForeverLM writes the picture and the link to the answer's place
        // itself (`answerBlock`), so the tutor is told what they show and
        // handed neither address.
        let shownLink = placeLink(for: question).flatMap { link in
            answerBlock(forQuestionAt: index, isCorrection: isCorrection)?.contains(link) == true ? placeName(for: question) : nil
        }
        if let alt = answerPictureLine(forQuestionAt: index, isCorrection: isCorrection).flatMap(Self.alt(ofPictureLine:)) {
            let link = shownLink.map { ", with a link to \($0) under it" } ?? ""
            lines.append("Picture for the answer: ForeverLM shows \"\(alt)\" with your feedback\(link), before the next question. Write no picture line or link for it; your words may refer to it.")
        } else {
            if pictureLine(for: question, shownWith: .answer) != nil {
                lines.append("This answer's picture is the one the learner has just been shown, so ForeverLM does not show it again: refer to no picture.")
            } else if grade.verdict != .correct, question.picture?.isShowable != true,
                      let sourceID = question.sourceID, let seconds = question.startSeconds {
                lines.append("No picture is stored for this question. If a slide or diagram around \(VideoQuizPlanning.timestamp(seconds)) makes the answer clearer, show it with show_source_image (source_id \(sourceID), at \(Int(seconds.rounded(.down))), cropped to the part that matters) beside the reference answer.")
            } else if grade.verdict != .correct, question.picture?.isShowable != true,
                      let sourceID = question.sourceID, let page = question.page {
                lines.append("If a figure, table or equation on page \(page) of the reading makes the answer clearer, show it with show_source_image (source_id \(sourceID), page \(page), cropped to the part that matters) beside the reference answer.")
            }
            if let shownLink {
                lines.append("ForeverLM puts a link to \(shownLink) under your feedback: write no link to it.")
            }
        }
        let readings = readingNumbers(for: question)
        for number in readings {
            let reading = request.readings[number - 1]
            lines.append("Planned reading R\(number): \(reading.link) (\(reading.place))")
        }
        if let memoryError {
            lines.append("Memory could not keep this question (\(memoryError)); tell the learner in a few words.")
        }
        lines.append("")
        if let next = currentIndex {
            lines.append(contentsOf: nextQuestionLines(next))
            let reading = readings.isEmpty ? "" : " Add the planned reading's link when the answer was missed."
            lines.append("Now reply: the feedback in your own words, making plain whether they had it, partly had it or missed it, the way a tutor would say it: a label such as Right or Not quite is not needed every time, so vary how you open. When they missed it, give the reference answer and why, from the lecture.\(reading) Then a blank line and the next question under its heading, exactly as written.")
        } else {
            if isCorrection {
                let missed = questions.enumerated()
                    .filter { verdicts[$0.element.id] != .correct }
                    .map { "\($0.offset + 1)" }
                lines.append("Correction recorded. Updated score: \(score.label).")
                if !missed.isEmpty {
                    lines.append("Not fully right: questions " + missed.joined(separator: ", ") + ".")
                } else {
                    lines.append("Every question is now fully right.")
                }
                let next = missed.isEmpty
                    ? "Tell them they have reached a fully right score."
                    : "Remind them they may answer any remaining not-fully-right question again to improve the score."
                lines.append("Now reply: the feedback on this revised answer, making plain whether they have it now, then the updated score. \(next)")
            } else {
                lines.append(contentsOf: resultLines)
                lines.append("Now reply: the feedback on this answer, making plain whether they had it, then \(closingSteps)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What the tutor learns from a skip: the question is settled with no
    /// grade, and what comes next. It carries no reference answer, so a
    /// retake still asks the question.
    func skipAcknowledgement(forQuestionAt index: Int) -> String {
        var lines = [
            "Question \(index + 1) of \(questions.count) skipped at the learner's request: no grade, nothing kept in Memory, and it counts as not right in the score.",
            "",
        ]
        let skip = "say in a few words that question \(index + 1) is skipped, with no verdict and without its answer"
        if let next = currentIndex {
            lines.append(contentsOf: nextQuestionLines(next))
            lines.append("Now reply: \(skip), then a blank line and the next question under its heading, exactly as written.")
        } else {
            lines.append(contentsOf: resultLines)
            lines.append("Now reply: \(skip), then \(closingSteps)")
        }
        return lines.joined(separator: "\n")
    }

    /// The next question as the tutor asks it: heading and words, and what
    /// to show with it.
    private func nextQuestionLines(_ next: Int) -> [String] {
        var lines = ["Next: \(heading(forQuestionAt: next)) — \(questions[next].question)"]
        if let note = questionPictureNote(for: questions[next]) {
            lines.append(note)
        }
        return lines
    }

    /// The sitting's result once its last question is settled: the score, the
    /// questions answered but not fully right, and those skipped.
    private var resultLines: [String] {
        var lines = ["That was the last question. Score: \(score.label)."]
        let missed = Set(questions.map(\.id).filter { id in verdicts[id].map { $0 != .correct } ?? false })
        if !missed.isEmpty {
            lines.append("Not fully right: questions \(numbers(of: missed)).")
        }
        if !skipped.isEmpty {
            lines.append("Skipped, and counted as not right: questions \(numbers(of: skipped)).")
        }
        return lines
    }

    /// How the tutor closes the quiz, after what it says of the last question.
    private var closingSteps: String {
        let skips = skipped.isEmpty ? "" : ", then the skipped questions in one line, without their answers, since a retake asks them again"
        let reading = request.readings.isEmpty ? "" : ", and the planned reading most worth doing, with its link"
        return "the score, then one line for each question answered but not fully right on what to take away\(skips), and the part of the lecture most worth rewatching\(reading). Tell them they may answer any not-fully-right question again here to improve the score, a skipped one included."
    }

    /// The model a quiz's chat grades on: the chat's own, exactly as the
    /// turn that called `grade_quiz_answer` runs on it (the chat's pick,
    /// else the Default Model), recorded in the ledger as a grade given in
    /// the chat. It follows the chat's host choice and, like the chat, has
    /// no backup models: the learner chose the model they are talking to.
    static func graderConfig(forChat config: AITaskConfig) -> AITaskConfig {
        var grader = config
        grader.taskLabel = QuizGrading.chatTaskLabel
        return grader
    }

    /// The grading model, for a failure another model could get past.
    struct GraderModel: Equatable {
        /// "Claude Sonnet 5", "Nemotron Nano 9B V2 (free)", as the pickers
        /// name it.
        let name: String
        let isFree: Bool
    }

    /// What the tutor learns when the grader gave no grade, once it has
    /// been asked again in place (`QuizGrading`). The product owner, 2026-09-27: a
    /// grade that keeps failing is likely a busy or free model, so the tutor
    /// proposes switching it. The grader is the chat's own model, so the
    /// switch is the chat's, in the model chip under the message box.
    /// `model` is nil for a failure every model would share (no connection,
    /// no key, no balance), where another model would fail the same way.
    static func gradingFailure(
        _ reason: String,
        questionNumber: Int,
        model: GraderModel?
    ) -> String {
        var because = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while because.hasSuffix(".") { because.removeLast() }
        var text = "Error: The grader could not grade this answer: \(because). Tell the learner it was not graded and why, and ask them to send their answer to question \(questionNumber) again. Do not grade it yourself."
        guard let model else { return text }
        text += "\nThe grader runs on \(model.name), the model this chat runs on"
        text += model.isFree
            ? ", a free model. Free models are shared and often overloaded or rate-limited, so the next answer may fail the same way."
            : "."
        text += " Propose switching this chat to another model with the model chip under the message box, in a sentence, and leave the choice to the learner: every answer is graded on the model the chat runs on."
        return text
    }
}

struct CourseQuizChatError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The courses a chat's attached lectures belong to, as the chat reads them.
/// The product owner, 2026-09-27, on a chat about Lecture 1 that offered to "quiz you on
/// it the same way" after Lecture 2 and searched the library for the next
/// lectures: "it should be aware that a course already has predefined quizzes
/// for each lecture". The course held both lectures and a written quiz after
/// each; the chat saw only a source titled like a lecture.
///
/// The block lists the lectures around the attached ones and the quizzes
/// placed after them, each quiz as a `foreverlm://quiz/<id>` link that opens
/// it in its own chat, where its own grader marks the answers and the score
/// lands on the quiz's row. It rides the cached catalog, so it is built when
/// sources are attached and holds nothing that changes with use: no scores and
/// no sitting in progress.
enum CourseChatOutline {
    /// What the block is built from, read in one storage call.
    struct Material: Sendable {
        var courses: [String: CourseMetadata]
        var lectures: [CourseSession]
        var items: [CourseLectureItem]
        var quizzes: [CourseQuiz]
        var sourceTitles: [String: String]
    }

    /// Lectures shown before the first attached one and after the last: the
    /// ones a learner asks about ("what's next") without the whole course
    /// riding every request.
    static let lecturesBefore = 2
    static let lecturesAfter = 4

    static let instruction = """
        Courses the attached lectures belong to. A course's quizzes are written ahead of time: each is a problem set on its lectures that ForeverLM grades itself, keeping the score on the quiz and sending missed questions to Memory. When the learner asks to be quizzed or tested on a lecture listed here, or when you would offer to quiz them on one, and a quiz follows that lecture, link that quiz, for example "take [Mitochondrial Dynamics](foreverlm://quiz/QUIZ_ID)", instead of writing questions of your own; the link opens it in its own chat. Write your own questions only for a lecture with no quiz here, or when the learner asks for questions beyond its quiz. When the learner asks which lecture comes next, answer from this outline rather than searching the library.
        """

    /// The block for the catalog, or "" when no attached source is a lecture.
    static func text(attachedSourceIDs: [String], material: Material) -> String {
        let attached = Set(attachedSourceIDs)
        let attachedLectureIDs = Set(
            material.items.filter { $0.sourceId.map(attached.contains) ?? false }.map(\.lectureId)
        )
        let lecturesByID = Dictionary(material.lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Courses in the order their lectures were attached.
        var courseIDs: [String] = []
        for sourceID in attachedSourceIDs {
            for item in material.items where item.sourceId == sourceID {
                guard let courseID = lecturesByID[item.lectureId]?.courseName,
                      !courseIDs.contains(courseID) else { continue }
                courseIDs.append(courseID)
            }
        }
        guard !courseIDs.isEmpty else { return "" }
        let itemsByLecture = Dictionary(grouping: material.items, by: \.lectureId)
        let sections = courseIDs.map { courseID in
            section(
                courseID: courseID,
                material: material,
                attached: attached,
                attachedLectureIDs: attachedLectureIDs,
                itemsByLecture: itemsByLecture
            )
        }
        return ([instruction] + sections).joined(separator: "\n\n")
    }

    private static func section(
        courseID: String,
        material: Material,
        attached: Set<String>,
        attachedLectureIDs: Set<String>,
        itemsByLecture: [String: [CourseLectureItem]]
    ) -> String {
        let lectures = material.lectures
            .filter { $0.courseName == courseID }
            .sorted { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number }
        let numbers = Dictionary(lectures.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        let quizzes = material.quizzes.filter { $0.courseID == courseID && !$0.questions.isEmpty }
        let placements = CourseQuizPlanning.placements(quizzes: quizzes, lectureOrder: lectures.map(\.id))
        let attachedIndexes = lectures.indices.filter { attachedLectureIDs.contains(lectures[$0].id) }
        let low = max(0, (attachedIndexes.first ?? 0) - lecturesBefore)
        let high = min(lectures.count - 1, (attachedIndexes.last ?? 0) + lecturesAfter)

        let title = material.courses[courseID]?.title.flatMap { $0.isEmpty ? nil : $0 } ?? courseID
        var lines = [
            "Course \"\(title)\" (course_id: \(courseID)): \(lectures.count) lecture\(lectures.count == 1 ? "" : "s"), \(quizzes.isEmpty ? "no quizzes written yet" : "\(quizzes.count) quiz\(quizzes.count == 1 ? "" : "zes") written")."
        ]
        if low > 0 {
            lines.append("(\(low) earlier lecture\(low == 1 ? "" : "s") not listed)")
        }
        for lecture in lectures[low...high] {
            let items = (itemsByLecture[lecture.id] ?? [])
                .sorted { $0.sortIndex == $1.sortIndex ? $0.id < $1.id : $0.sortIndex < $1.sortIndex }
            let primary = items.first { $0.role != .reading && $0.sourceId != nil }?.sourceId
            let name = lecture.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? primary.flatMap { material.sourceTitles[$0] }
                ?? "Lecture \(lecture.number)"
            var line = "\(lecture.number). " + (primary.map { sourceLink(name, id: $0) } ?? name)
            if items.contains(where: { $0.sourceId.map(attached.contains) ?? false }) {
                line += " (attached to this chat)"
            }
            lines.append(line)
            for quiz in placements.afterLecture[lecture.id] ?? [] {
                lines.append("   ▸ " + quizLine(quiz, numbers: numbers))
            }
        }
        let later = lectures.count - 1 - high
        if later > 0 {
            lines.append("(\(later) later lecture\(later == 1 ? "" : "s") not listed)")
            // A checkpoint on an attached lecture can sit past the window
            // when the course spaces its checkpoints widely.
            for lecture in lectures[(high + 1)...] {
                for quiz in placements.afterLecture[lecture.id] ?? []
                where quiz.kind != .practice && !Set(quiz.lectureIDs).isDisjoint(with: attachedLectureIDs) {
                    lines.append("   ▸ " + quizLine(quiz, numbers: numbers))
                }
            }
        }
        for quiz in placements.atEnd {
            lines.append("End of course ▸ " + quizLine(quiz, numbers: numbers))
        }
        return lines.joined(separator: "\n")
    }

    private static func quizLine(_ quiz: CourseQuiz, numbers: [String: Int]) -> String {
        let covered = quiz.lectureIDs.compactMap { numbers[$0] }.sorted()
        let span: String
        if let first = covered.first, let last = covered.last {
            span = first == last ? "lecture \(first)" : "lectures \(first)–\(last)"
        } else {
            span = "the course"
        }
        let kind: String
        switch quiz.kind {
        case .practice: kind = "practice quiz on \(span)"
        case .checkpoint: kind = "checkpoint quiz on \(span)"
        case .test: kind = "course test on \(span)"
        }
        let count = "\(quiz.questions.count) question\(quiz.questions.count == 1 ? "" : "s")"
        let link = "[\(linkText(quiz.title))](\(StudioEntityLink.quiz(quiz.id).markdownDestination))"
        return "\(link): \(kind), \(count)"
    }

    private static func sourceLink(_ title: String, id: String) -> String {
        "[\(linkText(title))](foreverlm://source/\(StudioEntityLink.encode(id)))"
    }

    private static func linkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }
}
