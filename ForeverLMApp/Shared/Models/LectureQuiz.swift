import Foundation

/// The pieces a course's quizzes share with the practice quiz after each
/// lecture: a lecture's numbered lines, a sitting's outcomes and score, and
/// the practice quiz's pace. The quizzes themselves are `CourseQuiz`; the
/// design record is docs/lecture-quiz-design.md.

/// One line of a lecture's transcript as the writer reads it: numbered so the
/// model can name the stretch a question rests on, with the time it is said
/// at when the transcript carries one.
struct LectureQuizLine: Equatable, Sendable {
    let number: Int
    let seconds: Double?
    let text: String
    /// The one-based page it is on, for a paged text such as a book chapter
    /// (`CourseQuizPlanning.pagedLines`); nil for a transcript or notes.
    var page: Int? = nil

    /// `12`, `12 · 4:05` or `12 · p.5`: the line as a writer's bracket names it.
    var label: String {
        if let seconds { return "\(number) · \(VideoQuizPlanning.timestamp(seconds))" }
        if let page { return "\(number) · p.\(page)" }
        return "\(number)"
    }
}

/// A timed transcript's lines as a quote is placed in them: when the lecture
/// says a question's words, for its Rewatch link and its slide.
///
/// A line's time is when its block starts, and a YouTube transcript's block
/// is some thirty seconds of captions (`YouTubeTranscriptService`, 35 to 75
/// words). A question timed from its block's start sent the learner back
/// before the point it asked about: the product owner, 2026-09-28, of a quiz on
/// "Mitochondrial Cell Biology 3", "the timing for each of these timestamps
/// for the videos is usually too early". Measured against YouTube's own
/// captions, the library's 265 timed quiz questions opened a median 23 s
/// before their quote was said, and 45 s at worst. Within a block the
/// captions run at an even pace, so the quote's share of the letters before
/// it is its share of the time: the same questions placed that way open a
/// median 2 s before the quote, 82 in 100 within 3 s, in the lectures whose
/// markers sit on their words.
struct LectureQuizTimeline {
    /// A moment before the quote's first word, so a rewatch opens on the
    /// sentence rather than inside it, never before the quote's own line.
    static let leadSeconds: Double = 2

    private let lines: [LectureQuizLine]
    private let text: MemoryGroundingText
    /// Where each line's words begin in `text`, in its letters and digits.
    private let starts: [Int]
    /// The timed lines as (where they begin, when), in order.
    private let anchors: [(letter: Int, seconds: Double)]

    init(_ lines: [LectureQuizLine]) {
        self.lines = lines
        text = MemoryGroundingText(lines.map(\.text).joined(separator: "\n"))
        var starts: [Int] = []
        var total = 0
        for line in lines {
            starts.append(total)
            total += MemoryGroundingText(line.text).letterCount
        }
        self.starts = starts
        anchors = lines.indices.compactMap { index in
            lines[index].seconds.map { (starts[index], $0) }
        }
    }

    /// Whether any line carries a time.
    var isTimed: Bool { !anchors.isEmpty }

    /// When the lecture says `quote`, a few seconds early (`leadSeconds`), in
    /// whole seconds; nil when the transcript is untimed or the quote is not
    /// its words. With `numbers`, the quote is looked for only in those
    /// lines, the stretch a question rests on.
    func seconds(saying quote: String, within numbers: ClosedRange<Int>? = nil) -> Double? {
        guard isTimed else { return nil }
        var minimum = 0
        var limit = text.letterCount
        if let numbers {
            guard let first = lines.firstIndex(where: { numbers.contains($0.number) }),
                  let last = lines.lastIndex(where: { numbers.contains($0.number) }) else { return nil }
            minimum = starts[first]
            if last + 1 < starts.count { limit = starts[last + 1] }
        }
        guard let offset = text.offset(of: quote, from: minimum), offset < limit,
              let before = anchors.last(where: { $0.letter <= offset }) else { return nil }
        let estimate: Double
        if let after = anchors.first(where: { $0.letter > offset }) {
            // Markers out of order are no pace to read; the line's own time stands.
            estimate = after.seconds > before.seconds
                ? before.seconds + (after.seconds - before.seconds)
                    * Double(offset - before.letter) / Double(after.letter - before.letter)
                : before.seconds
        } else if let first = anchors.first, before.letter > first.letter, before.seconds > first.seconds {
            // The last timed line has no next time: it runs at the lecture's pace.
            let pace = (before.seconds - first.seconds) / Double(before.letter - first.letter)
            estimate = before.seconds + pace * Double(offset - before.letter)
        } else {
            estimate = before.seconds
        }
        return max(before.seconds, estimate - Self.leadSeconds).rounded(.down)
    }
}

enum LectureQuizError: LocalizedError, Equatable {
    case noTranscript
    case notConfigured(String)
    case noQuestions

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "This lecture has no transcript to quiz you on yet."
        case .notConfigured(let message):
            return message
        case .noQuestions:
            return "The model returned no questions this transcript supports."
        }
    }
}

/// A practice quiz's pace and the transcript as its writer reads it. The
/// answer is checked by `CourseQuizPlanning.questions`.
enum LectureQuizPlanning {
    /// The same long-context budget the video checkpoints use.
    static let transcriptCharacterBudget = VideoQuizPlanning.transcriptCharacterBudget
    /// Room for the learning points the writer lists first and a question
    /// on each of them.
    static let writerMaxTokens = 24_000
    /// A practice quiz covers every learning point of its lecture, the way a
    /// textbook chapter's problems do (product owner, 2026-09-26: "they should
    /// really try to cover all the learning points"; 2026-09-27: first
    /// "identify all the key points in the video … and then make questions
    /// for all of them"). The writer lists the points before any question.
    static let minimumQuestions = 8
    static let maximumQuestions = CourseQuizPlanning.maximumQuestionsPerQuiz
    /// A transcript shorter than this has nothing to quiz.
    static let minimumLines = 3

    /// About one question per two and a half minutes of lecture, eight to
    /// sixty; fifteen for untimed material. The writer is told this is the
    /// least the lecture needs and that its list of learning points decides
    /// the real count.
    static func targetQuestionCount(spanSeconds: Double?) -> Int {
        guard let spanSeconds, spanSeconds.isFinite, spanSeconds > 0 else { return 15 }
        return min(maximumQuestions, max(minimumQuestions, Int((spanSeconds / 150).rounded())))
    }

    /// The transcript as the writer reads it: one `[n]`, `[n · m:ss]` or, for
    /// a reading, `[n · p.5]` line per block, cut at the budget on a line
    /// boundary.
    static func transcriptBlock(
        _ lines: [LectureQuizLine],
        budget: Int = transcriptCharacterBudget
    ) -> (text: String, truncated: Bool) {
        var output: [String] = []
        var used = 0
        for line in lines {
            let rendered = "[\(line.label)] \(line.text)"
            if used + rendered.count + 1 > budget, !output.isEmpty {
                return (output.joined(separator: "\n"), true)
            }
            output.append(rendered)
            used += rendered.count + 1
        }
        return (output.joined(separator: "\n"), false)
    }
}
