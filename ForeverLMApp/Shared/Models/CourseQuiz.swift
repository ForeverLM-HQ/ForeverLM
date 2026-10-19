import Foundation

extension CourseQuizNaming {
    /// The title a quiz's writer produced, kept only where it names what the
    /// quiz is about: the course test stays the course test.
    static func title(for slot: CourseQuizSlot, written raw: String?) -> String {
        guard slot.kind != .test, let title = cleanTitle(raw) else { return slot.title }
        return title
    }

    /// What the user message asks for beside the questions. It is not part
    /// of the task's editable prompt, so an edited prompt still names quizzes.
    static let draftNamingInstruction = """
        Also name the quiz by what its questions cover. Add to the JSON object:
        "title": two to six words naming the topics, in title case, without the word "Quiz" (for example "Cristae and Supercomplexes");
        "symbol": the name of one SF Symbol that suits those topics (for example "bolt.heart", "atom", "leaf", "function").
        """
}

/// The writers' answer before `CourseQuizPlanning.questions` checks it. A
/// practice quiz reads one part; a checkpoint or the test reads one part per
/// lecture, and each question names the part it is about.
struct CourseQuizDraft: Decodable, Equatable, Sendable {
    struct Question: Decodable, Equatable, Sendable {
        let part: Int?
        let firstLine: Int?
        let lastLine: Int
        let question: String
        let answer: String
        let keyPoints: [String]?
        let quote: String?
        /// "recall", "explain", "apply" or "challenge" (`CourseQuizQuestion.Level`).
        var level: String? = nil
        /// A slide of the part to show with the question, by the number the
        /// material lists it under (`CourseQuizPictures`).
        var slide: Int? = nil
        /// "question" or "answer": when the slide is shown.
        var slideWith: String? = nil
        /// What the slide shows, in a few words, for its alt text.
        var slideShows: String? = nil
        /// A figure of a reading part to show with the question, by the
        /// number the material lists it under.
        var figure: Int? = nil
        var figureWith: String? = nil
        var figureShows: String? = nil
        /// A picture for ForeverLM to draw, where nothing on screen or in the
        /// reading shows the point: what it must show.
        var draw: String? = nil
        var drawWith: String? = nil
        var drawShows: String? = nil
        /// The numbers of the draft's learning points the question tests,
        /// counting from 1.
        var points: [Int]? = nil

        enum CodingKeys: String, CodingKey {
            case part, level, slide, figure, draw, points
            case slideWith = "slide_with"
            case slideShows = "slide_shows"
            case figureWith = "figure_with"
            case figureShows = "figure_shows"
            case drawWith = "draw_with"
            case drawShows = "draw_shows"
            case firstLine = "first_line"
            case lastLine = "last_line"
            case question, answer, quote
            case keyPoints = "key_points"
        }
    }

    let questions: [Question]
    /// Every key point and fact of the material, listed before any question
    /// (`CourseQuizPlanning.uncoveredPoints` checks each has one).
    var learningPoints: [String]? = nil
    /// Two to six words naming the topics the questions cover.
    var title: String? = nil
    /// An SF Symbol for those topics.
    var symbol: String? = nil

    enum CodingKeys: String, CodingKey {
        case questions, title, symbol
        case learningPoints = "learning_points"
    }
}

extension CourseQuizDraft.Question {
    /// The same question about another part of the material.
    func moved(toPart part: Int) -> CourseQuizDraft.Question {
        var moved = CourseQuizDraft.Question(
            part: part, firstLine: firstLine, lastLine: lastLine,
            question: question, answer: answer, keyPoints: keyPoints, quote: quote
        )
        moved.level = level
        moved.slide = slide
        moved.slideWith = slideWith
        moved.slideShows = slideShows
        moved.figure = figure
        moved.figureWith = figureWith
        moved.figureShows = figureShows
        moved.draw = draw
        moved.drawWith = drawWith
        moved.drawShows = drawShows
        moved.points = points
        return moved
    }
}

/// One lecture's material as a writer reads it: the source the questions will
/// rest on and its numbered lines. A lecture's reading is a part of its own,
/// the chapter's lines on the planned pages, so its questions rest on the
/// book, not the video.
struct CourseQuizPart: Equatable, Sendable {
    let lectureID: String
    let lectureTitle: String
    let sourceID: String
    let lines: [LectureQuizLine]
    /// The lecture video's captured slides, for the writer to pin to a
    /// question; empty when its slides were never captured.
    var slides: [CourseQuizSlide] = []
    /// A reading's captioned figures on its planned pages, for the writer to
    /// pin to a question; empty for a lecture, and for a reading whose file
    /// is not on this Mac or prints no figure captions.
    var figures: [CourseQuizFigure] = []
    /// Set when the part is a reading assigned with the lecture rather than
    /// the lecture itself.
    var reading: CourseQuizPartReading? = nil
}

/// What a reading part is (docs/lecture-quiz-design.md, "Readings"): a
/// textbook reading the course planned for a lecture, or a source filed under
/// the lecture as its reading.
struct CourseQuizPartReading: Equatable, Sendable {
    /// The sections it covers as the book titles them, or the source's title.
    let title: String
    /// "Bioenergetics 4, Chapter 8: Transporters, pages 2–8".
    let place: String
    /// One-based pages within the source; nil when it is read whole.
    let pages: ClosedRange<Int>?
}

/// A captured slide as a quiz writer reads it: its number in the material,
/// the picture it becomes, when it came on screen, the stretches it stayed
/// on screen and the words on it.
struct CourseQuizSlide: Equatable, Sendable {
    let number: Int
    let reference: SourceImageReference
    let seconds: Double
    let text: String
    /// Each stretch of the talk the slide was on screen, windows that touch
    /// joined; empty for a deck stored before windows had ends.
    var onScreen: [ClosedRange<Double>] = []
}

/// A reading's figure as a quiz writer reads it: its number in the material,
/// the picture it becomes (its page cropped to the figure, or an EPUB
/// chapter's image), the page it is on and its printed caption.
struct CourseQuizFigure: Equatable, Sendable {
    let number: Int
    let reference: SourceImageReference
    let page: Int?
    let caption: String
    /// The label a PDF prints for it ("Figure 2"), which a walkthrough's
    /// figure step names; nil for an EPUB chapter's picture.
    var label: String?
}

/// Pictures a quiz writer pins to questions (`CourseQuizPicture`): the slides
/// listed after each lecture's lines, the figures listed after each reading's,
/// the pictures it may ask ForeverLM to draw, and what the writer is asked for.
enum CourseQuizPictures {
    /// Slides listed per lecture, and the words kept from each.
    static let maximumSlidesPerPart = 60
    static let maximumSlideTextCharacters = 180
    /// Figures listed per reading, and the caption words kept from each.
    static let maximumFiguresPerPart = 30
    static let maximumFigureCaptionCharacters = 220
    /// Pictures ForeverLM draws for one quiz in one run. The product owner,
    /// 2026-09-27: "by default, it should try to have an image for each
    /// question … link to an image, in the course page or … generate one …
    /// whenever it's helpful". So a quiz aims for a picture on every question
    /// a picture helps: a slide or a figure of the course's own material
    /// first, and a drawing where none shows the point. Twelve covers the
    /// questions of a practice quiz (fifteen or so) that its lecture's slides
    /// and its reading's figures leave bare, while bounding the cost: each
    /// drawing is one image request on the learner's image model, a few cents
    /// on the default one, and a checkpoint or the test, which revisit
    /// lectures whose slides are already listed, rarely needs more.
    static let maximumDrawingsPerQuiz = 12

    /// The slides of a lecture video's stored content, numbered from 1 in
    /// the order they came on screen. Photographs of the room are left out.
    /// A YouTube video's slide becomes the frame at `pictureSeconds`, which
    /// any Mac can capture again from the stream; a recording's stays its
    /// stored slide frame.
    static func slides(from content: String, sourceID: String, byMoment: Bool) -> [CourseQuizSlide] {
        let parsed = YouTubeSlideContentParser.parse(content)
        let stored = parsed.slides.filter { !$0.isNonSlide }
        // Every stored window, photographs of the room too: whichever closes
        // last is the one the storyboard's final sample closed.
        let talkEnd = parsed.slides.flatMap(\.windows).compactMap(\.end).max()
        var slides: [CourseQuizSlide] = []
        for frame in stored.sorted(by: { ($0.timeSeconds ?? 0) < ($1.timeSeconds ?? 0) }) {
            guard let seconds = frame.timeSeconds, let shown = pictureSeconds(of: frame, talkEnd: talkEnd),
                  slides.count < maximumSlidesPerPart else { continue }
            let location: SourceImageReference.Location = byMoment ? .moment(Int(shown.rounded(.down))) : .slide(frame.index)
            let words = frame.recognizedText
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            slides.append(CourseQuizSlide(
                number: slides.count + 1,
                reference: SourceImageReference(sourceID: sourceID, location: location),
                seconds: seconds,
                text: words.count > maximumSlideTextCharacters
                    ? String(words.prefix(maximumSlideTextCharacters)) + "…"
                    : words,
                onScreen: stretches(of: frame)
            ))
        }
        return slides
    }

    /// How long before the end of its time on screen a slide's picture is
    /// taken. A stored window closes midway between the last sample that
    /// showed the slide and the first that did not, so its last seconds may
    /// already be the next slide. YouTube's storyboards sample every 5 or 10
    /// seconds, so 10 seconds before the end is at or before the last sample
    /// that showed it.
    static let pictureSecondsBeforeEnd: Double = 10

    /// When a slide's picture is taken: 10 seconds before the end of the
    /// longest stretch it was on screen (the later of two as long), never
    /// before that stretch's middle. A lecturer builds a slide while talking
    /// — Kowaltowski's bioenergetics slides open on a title and the speaker
    /// and fill with a diagram and equations over minutes — so the moment it
    /// came on screen is when it is emptiest, and the moment before it goes
    /// is when everything it builds is there.
    ///
    /// The stretch that closes the talk (its end is `talkEnd`, the latest of
    /// any stored window) is taken twice as far back, never before its start.
    /// Nothing follows it, so its window closes a sample interval after the
    /// storyboard's last sample, and that sample can itself lie past the
    /// video's end: "Mitochondrial Cell Biology 3" closes its last window at
    /// 16:50 and runs 16:35. A frame past the end cannot be captured.
    ///
    /// A deck stored before windows had ends keeps its one time, which there
    /// is the stored frame's own, taken mid-run; nil only for a slide with no
    /// time at all.
    static func pictureSeconds(of frame: YouTubeSlideFrameContext, talkEnd: Double? = nil) -> Double? {
        let longest = stretches(of: frame).max { first, second in
            (first.upperBound - first.lowerBound, first.lowerBound) < (second.upperBound - second.lowerBound, second.lowerBound)
        }
        guard let longest else { return frame.timeSeconds }
        if let talkEnd, longest.upperBound >= talkEnd {
            return max(longest.lowerBound, longest.upperBound - 2 * pictureSecondsBeforeEnd)
        }
        let middle = longest.lowerBound + (longest.upperBound - longest.lowerBound) / 2
        return max(middle, longest.upperBound - pictureSecondsBeforeEnd)
    }

    /// A slide's windows with an end, in order, those that touch joined: the
    /// scan splits a run where one sample differs from the next, and the
    /// capture then finds both halves the same slide, so the slide stayed up
    /// throughout.
    static func stretches(of frame: YouTubeSlideFrameContext) -> [ClosedRange<Double>] {
        var joined: [ClosedRange<Double>] = []
        for window in frame.windows.sorted(by: { $0.start < $1.start }) {
            guard let end = window.end else { continue }
            if let last = joined.last, window.start - last.upperBound <= 1 {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                joined.append(window.start...max(window.start, end))
            }
        }
        return joined
    }

    /// `[S3 · 12:03–14:40] Inner Mitochondrial Membrane Phospholipids
    /// Cardiolipin`, one line per slide with each stretch it was on screen
    /// (`[S3 · 12:03]` for a deck stored before windows had ends), under a
    /// heading of its own. Over the budget the slides are sampled evenly
    /// through the talk, keeping their numbers.
    static func block(_ slides: [CourseQuizSlide], heading: String, budget: Int = .max) -> String? {
        let rendered = slides.map { slide in
            let words = slide.text.isEmpty ? "(no words recognized)" : slide.text
            let times = slide.onScreen.isEmpty
                ? VideoQuizPlanning.timestamp(slide.seconds)
                : slide.onScreen.map { "\(VideoQuizPlanning.timestamp($0.lowerBound))–\(VideoQuizPlanning.timestamp($0.upperBound))" }
                    .joined(separator: ", ")
            return "[S\(slide.number) · \(times)] \(words)"
        }
        return sampledBlock(rendered, heading: heading, budget: budget)
    }

    /// `[F2 · p.5] Figure 8-3. The rotor of ATP synthase …`, one line per
    /// figure of a reading, under a heading of its own; sampled evenly like
    /// the slides when over the budget.
    static func figureBlock(_ figures: [CourseQuizFigure], heading: String, budget: Int = .max) -> String? {
        let rendered = figures.map { figure in
            let page = figure.page.map { " · p.\($0)" } ?? ""
            return "[F\(figure.number)\(page)] \(figure.caption.isEmpty ? "(no caption)" : figure.caption)"
        }
        return sampledBlock(rendered, heading: heading, budget: budget)
    }

    private static func sampledBlock(_ rendered: [String], heading: String, budget: Int) -> String? {
        guard !rendered.isEmpty else { return nil }
        let total = rendered.reduce(0) { $0 + $1.count + 1 }
        var lines = [heading]
        if total <= budget {
            lines += rendered
        } else {
            let keepFraction = Double(max(budget, 0)) / Double(total)
            var credit = 0.0
            for line in rendered {
                credit += keepFraction
                if credit >= 1 {
                    credit -= 1
                    lines.append(line)
                }
            }
            guard lines.count > 1 else { return nil }
        }
        return lines.joined(separator: "\n")
    }

    /// A reading's figures as the writer lists them, numbered from 1 in the
    /// order found, the caption cut to `maximumFigureCaptionCharacters`.
    static func figures(from found: [(reference: SourceImageReference, page: Int?, caption: String)]) -> [CourseQuizFigure] {
        found.prefix(maximumFiguresPerPart).enumerated().map { offset, entry in
            let words = entry.caption.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return CourseQuizFigure(
                number: offset + 1,
                reference: entry.reference,
                page: entry.page,
                caption: words.count > maximumFigureCaptionCharacters
                    ? String(words.prefix(maximumFigureCaptionCharacters)) + "…"
                    : words
            )
        }
    }

    /// What the user message asks for beside the questions when the material
    /// lists slides. Like the naming, it is not part of the task's editable
    /// prompt, so an edited prompt still pins pictures.
    static let draftInstruction = """
        The material lists the lecture's slides after its lines: [S3 · 12:03–14:40] and the words recognized on the slide, where 12:03–14:40 is when it was on screen (a slide shown more than once lists each time). The learner sees the slide as it stands at the end of its longest time on screen, with everything built on it by then, so it can show what the lines of that time explain. Aim for a picture on every question a picture helps, and show a slide with a question wherever seeing it makes the question's point clearer: a diagram, a structure, a graph, a pathway, a table, an equation. For such a question add to its JSON object:
        "slide": the slide's number, 3 for [S3], from the part the question is about;
        "slide_with": "question" when the learner needs to see it to answer and it does not show the answer, and the question may then point at it ("the structure on this slide"); "answer" when the slide shows or states the answer, so it is shown only once they have answered. A slide on screen while the answer was explained usually shows it; when in doubt, "answer";
        "slide_shows": what the slide shows, in a few words that never give the answer away.
        Leave the three out when no listed slide shows the question's point, when the slide holds only a title, a list of words the question asks the learner to recall, or the speaker.
        """

    /// The same for a reading's figures, when the material lists them.
    static let figureInstruction = """
        The material lists a reading's figures after its lines: [F2 · p.5] and the figure's printed caption. Aim for a picture on every question a picture helps, and show a figure with a question wherever seeing it makes the question's point clearer: a diagram, a structure, a graph, a pathway, a table. For such a question add to its JSON object:
        "figure": the figure's number, 2 for [F2], from the part the question is about;
        "figure_with": "question" when the learner needs to see it to answer, and the question may then point at it ("the structure in this figure"); "answer" when the figure shows or states the answer, so it is shown only once they have answered;
        "figure_shows": what the figure shows, in a few words that never give the answer away.
        Leave the three out when no listed figure shows the question's point.
        """

    /// What the writer and the picker are told when ForeverLM may draw
    /// pictures for this quiz: where no slide or figure shows a point a
    /// picture would make clear, a brief for one, at most `limit` of them.
    static func drawInstruction(limit: Int) -> String {
        """
        Aim for a picture on every question a picture would help. Where a question's point is a mechanism, a structure, a pathway, a cycle, a comparison or an arrangement that a picture would make clear, and no listed slide or figure shows it, ForeverLM draws one: up to \(limit) for this quiz, one for each such question. For such a question add to its JSON object:
        "draw": what the picture must show — the one idea it makes visible, what is drawn and how the parts relate, and the few things labelled — taken only from the material, with no numbers or data it does not give;
        "draw_with": "question" when the learner needs to see it to answer, and the picture must then neither show nor label the answer; "answer" when it shows the answer, so it is shown only once they have answered;
        "draw_shows": what the picture shows, in a few words that never give the answer away.
        A question a listed slide or figure shows gets that instead; never ask for a drawing of words the learner must recall.
        """
    }

    /// The picture a writer pinned to a question: a slide, a figure, or a
    /// drawing briefed, in that order; nil when it named none the part has.
    static func picture(for raw: CourseQuizDraft.Question, in part: CourseQuizPart) -> CourseQuizPicture? {
        picture(slide: raw.slide, with: raw.slideWith, shows: raw.slideShows, in: part)
            ?? picture(figure: raw.figure, with: raw.figureWith, shows: raw.figureShows, in: part)
            ?? drawing(raw.draw, with: raw.drawWith, shows: raw.drawShows)
    }

    /// The picture a writer pinned to a question, or nil when the slide it
    /// names is not in the part.
    static func picture(slide number: Int?, with placement: String?, shows caption: String?, in part: CourseQuizPart) -> CourseQuizPicture? {
        guard let number, let slide = part.slides.first(where: { $0.number == number }) else { return nil }
        return CourseQuizPicture(reference: slide.reference, caption: caption, placement: self.placement(placement))
    }

    /// The figure a writer pinned, or nil when the reading lists no such figure.
    static func picture(figure number: Int?, with placement: String?, shows caption: String?, in part: CourseQuizPart) -> CourseQuizPicture? {
        guard let number, let figure = part.figures.first(where: { $0.number == number }) else { return nil }
        return CourseQuizPicture(reference: figure.reference, caption: caption, placement: self.placement(placement))
    }

    /// A drawing briefed, waiting to be drawn; nil for an empty brief.
    static func drawing(_ brief: String?, with placement: String?, shows caption: String?) -> CourseQuizPicture? {
        guard let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty else { return nil }
        return .awaitingDrawing(brief: brief, caption: caption, placement: self.placement(placement))
    }

    /// A missing or unknown placement holds the picture for the answer.
    private static func placement(_ text: String?) -> CourseQuizPicture.Placement {
        text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap(CourseQuizPicture.Placement.init(rawValue:)) ?? .answer
    }

    /// The questions with at most `limit` drawings briefed, the first in
    /// order kept; a brief past the limit is dropped, not deferred, so a
    /// quiz never waits on drawings no run was going to pay for.
    static func limitingDrawings(_ questions: [CourseQuizQuestion], to limit: Int) -> [CourseQuizQuestion] {
        var briefed = 0
        return questions.map { question in
            guard question.picture?.isAwaitingDrawing == true else { return question }
            briefed += 1
            guard briefed > limit else { return question }
            var trimmed = question
            trimmed.picture = nil
            return trimmed
        }
    }

    /// A rewritten quiz keeps the pictures its questions already had in the
    /// image store — drawn for them or pinned by an assistant — where the
    /// same question comes back (same id) with nothing better than a brief:
    /// a slide or a figure named now still wins, and nothing is drawn twice.
    static func keepingStoredPictures(_ questions: [CourseQuizQuestion], from previous: [CourseQuizQuestion]) -> [CourseQuizQuestion] {
        var stored: [String: CourseQuizPicture] = [:]
        for question in previous where stored[question.id] == nil {
            if let picture = question.picture, picture.storedImageID != nil { stored[question.id] = picture }
        }
        guard !stored.isEmpty else { return questions }
        return questions.map { question in
            guard question.picture == nil || question.picture?.isAwaitingDrawing == true,
                  let kept = stored[question.id] else { return question }
            var carried = question
            carried.picture = kept
            return carried
        }
    }

    // MARK: Pictures for a quiz already written

    /// Slides and figures listed for one quiz's picture pass, shared by its parts.
    static let pickerSlideBudget = 40_000

    /// The parts a picture pass lists: every part with slides or figures to
    /// show, and with drawing every part, since a picture can then be drawn
    /// for any question.
    static func pictureParts(_ parts: [CourseQuizPart], drawing: Bool) -> [CourseQuizPart] {
        parts.filter { drawing || !$0.slides.isEmpty || !$0.figures.isEmpty }
    }

    /// The questions of a quiz already written that a picture pass may give
    /// a picture: on a lecture video whose slides are captured or a reading
    /// whose figures are listed (with `drawing`, on any part), and without
    /// one unless `replacing`. Indices into the quiz's questions.
    static func candidates(in quiz: CourseQuiz, parts: [CourseQuizPart], replacing: Bool, drawing: Bool = false) -> [Int] {
        let pictured = Set(pictureParts(parts, drawing: drawing).map(\.sourceID))
        return quiz.questions.indices.filter { index in
            let question = quiz.questions[index]
            guard let sourceID = question.sourceID, pictured.contains(sourceID) else { return false }
            return replacing || question.picture == nil
        }
    }

    /// What the picker reads for a quiz already written: each lecture's
    /// slides and each reading's figures, then the questions it may picture,
    /// numbered as in the quiz, each with its part, its moment or page and
    /// its reference answer (so a picture that shows the answer is held for
    /// it).
    static func pickerMaterial(quiz: CourseQuiz, parts: [CourseQuizPart], candidates: [Int], drawing: Bool = false) -> String {
        let listed = pictureParts(parts, drawing: drawing)
        let perPart = pickerSlideBudget / max(listed.count, 1)
        var blocks: [String] = []
        for (offset, part) in listed.enumerated() {
            let number = offset + 1
            if let slides = block(part.slides, heading: "Part \(number): slides of \(part.lectureTitle)", budget: perPart) {
                blocks.append(slides)
            } else if let reading = part.reading,
                      let figures = figureBlock(part.figures, heading: "Part \(number): figures of the reading \(reading.title) (\(reading.place))", budget: perPart) {
                blocks.append(figures)
            } else {
                let name = part.reading.map { "the reading \($0.title) (\($0.place))" } ?? part.lectureTitle
                blocks.append("Part \(number): \(name), with no slide or figure listed; a picture for its questions can only be drawn.")
            }
        }
        let partNumbers = Dictionary(listed.enumerated().map { ($1.sourceID, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        var questions = ["Questions:"]
        for index in candidates {
            let question = quiz.questions[index]
            guard let sourceID = question.sourceID, let part = partNumbers[sourceID] else { continue }
            var head = "Q\(index + 1) · part \(part)"
            if let seconds = question.startSeconds {
                head += " · at \(VideoQuizPlanning.timestamp(seconds))"
            } else if let page = question.page {
                head += " · p.\(page)"
            }
            if let level = question.level { head += " · \(level.rawValue)" }
            questions.append("\(head): \(question.question)")
            questions.append("   Reference answer: \(question.answer)")
        }
        blocks.append(questions.joined(separator: "\n"))
        return blocks.joined(separator: "\n\n")
    }

    /// The picker's answer: which slide, figure or drawing goes with which
    /// question.
    struct PickDraft: Decodable, Equatable, Sendable {
        struct Pick: Decodable, Equatable, Sendable {
            let question: Int
            var slide: Int? = nil
            var slideWith: String? = nil
            var slideShows: String? = nil
            var figure: Int? = nil
            var figureWith: String? = nil
            var figureShows: String? = nil
            var draw: String? = nil
            var drawWith: String? = nil
            var drawShows: String? = nil

            enum CodingKeys: String, CodingKey {
                case question, slide, figure, draw
                case slideWith = "slide_with"
                case slideShows = "slide_shows"
                case figureWith = "figure_with"
                case figureShows = "figure_shows"
                case drawWith = "draw_with"
                case drawShows = "draw_shows"
            }
        }

        let pictures: [Pick]
    }

    /// The quiz's questions with the picker's pictures pinned, and how many
    /// it pinned. A pick for a question outside `candidates`, or naming a
    /// slide or figure its part does not have, is dropped, and so is a
    /// drawing past `drawingLimit`; the first pick for a question wins.
    /// Questions keep their ids, so their Memory items and the grades of a
    /// sitting under way stay with them.
    static func applying(
        _ draft: PickDraft,
        to quiz: CourseQuiz,
        parts: [CourseQuizPart],
        candidates: [Int],
        drawingLimit: Int = 0
    ) -> (questions: [CourseQuizQuestion], pinned: Int) {
        let allowed = Set(candidates)
        let partsBySource = Dictionary(parts.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        var questions = quiz.questions
        var done: Set<Int> = []
        var drawings = 0
        for pick in draft.pictures {
            let index = pick.question - 1
            guard allowed.contains(index), !done.contains(index),
                  let sourceID = questions[index].sourceID, let part = partsBySource[sourceID] else { continue }
            if let shown = picture(slide: pick.slide, with: pick.slideWith, shows: pick.slideShows, in: part)
                ?? picture(figure: pick.figure, with: pick.figureWith, shows: pick.figureShows, in: part) {
                questions[index].picture = shown
            } else if drawings < drawingLimit, let briefed = drawing(pick.draw, with: pick.drawWith, shows: pick.drawShows) {
                questions[index].picture = briefed
                drawings += 1
            } else {
                continue
            }
            done.insert(index)
        }
        return (questions, done.count)
    }

    // MARK: Drawing

    /// The questions whose briefed pictures wait to be drawn, at most
    /// `maximumDrawingsPerQuiz`, in quiz order. Indices into the questions.
    static func awaitingDrawing(in quiz: CourseQuiz) -> [Int] {
        Array(quiz.questions.indices.filter { quiz.questions[$0].picture?.isAwaitingDrawing == true }
            .prefix(maximumDrawingsPerQuiz))
    }

    /// What the image model is asked for one question's picture: a teaching
    /// diagram of the brief, in the walkthroughs' house style. The prompt is
    /// kept with the picture (`GeneratedImageStore`), so what made it can
    /// always be read back. A picture shown before the answer is told nothing
    /// of the answer; one shown with it may draw it.
    static func drawingPrompt(for question: CourseQuizQuestion, quizTitle: String, courseTitle: String?) -> String? {
        guard let picture = question.picture, let brief = picture.brief else { return nil }
        var lines: [String] = []
        let course = courseTitle.map { " of the course \"\($0)\"" } ?? ""
        lines.append("A teaching picture for one question of the quiz \"\(quizTitle)\"\(course).")
        lines.append("The question: \(question.question)")
        switch picture.placement {
        case .question:
            lines.append("The learner sees the picture before answering, so it must neither show nor label the answer.")
        case .answer:
            lines.append("The learner sees the picture with the answer: \(question.answer)")
        }
        lines.append("What the picture must show: \(brief)")
        lines.append("Style: a clear scientific diagram on a plain white background, flat colours, clean outlines. Label only what the brief names, in a few short words each, spelled exactly; no titles, captions, paragraphs or equations. Nothing decorative, no scenery, no people unless the brief asks for them. Invent no data: no plotted values, axes with numbers or measurements the brief does not give.")
        return lines.joined(separator: "\n")
    }
}

/// What the user message asks of a writer when the material holds readings
/// (docs/lecture-quiz-design.md, "Readings"). The product owner, 2026-09-27: the
/// quizzes should "also include readings, and cover really all the points
/// that are made". Like the naming, it is not part of the task's editable
/// prompt, so an edited prompt still quizzes the readings.
enum CourseQuizReadingInstructions {
    /// A practice quiz's pass over one reading, after its lecture's.
    static func practice(lecturePoints: [String]) -> String {
        var lines = [
            "This call is about a reading assigned with the lecture, not the lecture itself. The material below is the reading's text, one numbered block per line: [12 · p.5] text, where p.5 is the page it is on. Treat it as you would the lecture's transcript: go through it from its first line to its last and list in \"learning_points\" every key point and fact worth remembering it teaches (each claim, mechanism, definition, number with its unit, equation and what it means, result and the reason behind it, and what each figure or table shows as the text explains it), then ask at least one question about each, working up through the levels. \"first_line\" and \"last_line\" name the reading's lines. Leave out the book's running headers, page numbers, figure credits and references.",
            "Each question names the reading's subject so it stands alone (\"In the adenine nucleotide translocator, why …\"), never \"this lecture\".",
        ]
        let points = lecturePoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !points.isEmpty {
            lines.append("The lecture's own learning points, which its questions already ask about:")
            lines += points.enumerated().map { "- \($0.element)" }
            lines.append("Do not ask again about a point only the lecture makes. Where the reading goes deeper than the lecture, adds to it or explains it differently, ask about what the reading says; a question that ties the reading to the lecture is welcome, anchored in the reading's lines.")
        }
        return lines.joined(separator: "\n")
    }

    /// A checkpoint's or the course test's material, when it holds readings.
    static let parts = """
        Some parts are readings assigned with a lecture, titled "Reading with <lecture>: <sections> (<where they are>)"; their lines are [3.12 · p.5] text, where 3 is the part, 12 the line and p.5 the page. List each reading's learning points as you do each lecture's and ask about them the same way, and connect a reading to its lecture where the two meet. Leave out the book's running headers, page numbers, figure credits and references.
        """
}

/// A follow-up call for the learning points a writer listed and left without
/// a question (`CourseQuizPlanning.uncoveredPoints`), so every point the
/// material makes is asked about. The list is the writer's own, numbered as
/// it wrote it, so the new questions' "points" name the same numbers.
struct CourseQuizCoverage: Equatable, Sendable {
    let points: [String]
    /// Numbers of the points without a question, counting from 1.
    let missing: [Int]

    var instruction: String {
        var lines = ["Your list of learning points for this material was:"]
        lines += points.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines.append("These have no question yet: " + missing.map(String.init).joined(separator: ", ") + ".")
        lines.append("Write the questions for exactly these points, at the levels that suit them, in the same form as before, each naming in \"points\" the numbers from the list above. Return JSON only: {\"questions\": [...]}")
        return lines.joined(separator: "\n")
    }
}

/// A quiz the ladder plans before any question is written: its identity,
/// kind, title, the lectures it covers and where it goes.
struct CourseQuizSlot: Equatable, Sendable {
    let id: String
    let kind: CourseQuiz.Kind
    let title: String
    let lectureIDs: [String]
    let afterLectureID: String?
}

enum CourseQuizError: LocalizedError, Equatable {
    case courseNotFound(String)
    case nothingToQuiz
    case notConfigured(String)
    case noQuestions(String)

    var errorDescription: String? {
        switch self {
        case .courseNotFound(let id):
            return "No course \(id)."
        case .nothingToQuiz:
            return "None of this course's lectures has a transcript or text to quiz on yet."
        case .notConfigured(let message):
            return message
        case .noQuestions(let title):
            return "The model returned no questions the material supports for \(title)."
        }
    }
}

/// The deterministic half: the ladder, the identities, what the writers are
/// handed, and how their answers are checked. The model decides what to ask;
/// which quizzes exist, where they go and which lines a question rests on is
/// always code.
extension CourseQuizPlanning {
    static let defaultCheckpointEvery = 4
    static let checkpointEveryRange = 2...12
    /// Room for a comprehensive set: up to `maximumQuestionsPerQuiz`
    /// questions, each with its answer, key points and quote.
    static let writerMaxTokens = 24_000
    /// The same long-context budget the lecture quiz uses, shared across a
    /// checkpoint's or the test's parts.
    static let materialCharacterBudget = LectureQuizPlanning.transcriptCharacterBudget
    /// No one part takes more than this, so a four-lecture checkpoint reads
    /// each lecture well rather than the first one whole.
    static let maximumPartCharacters = 45_000
    static let maximumQuestionsPerQuiz = 60

    /// Gives each question its `questionID`. A question asking the same thing
    /// about the same source as one of `previous`, the version being
    /// replaced, keeps that one's id, so a question stored under a positional
    /// `qN` before content ids stays on its Memory item through the rewrite.
    /// The same question twice in one quiz takes a `-2`, `-3` suffix: a quiz
    /// chat keys its verdicts by id, so ids never repeat within a quiz.
    static func identified(
        _ questions: [CourseQuizQuestion],
        previous: [CourseQuizQuestion] = []
    ) -> [CourseQuizQuestion] {
        func key(_ question: CourseQuizQuestion) -> [String] {
            [question.sourceID ?? "", question.question.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        var carried: [[String]: [String]] = [:]
        for question in previous { carried[key(question), default: []].append(question.id) }
        var used: Set<String> = []
        return questions.map { question in
            let questionKey = key(question)
            let keptID = carried[questionKey]?.first(where: { !used.contains($0) })
            if let keptID { carried[questionKey]?.removeAll { $0 == keptID } }
            let base = questionID(sourceID: question.sourceID, question: question.question)
            var id = keptID ?? base
            var suffix = 1
            while keptID == nil, used.contains(id) {
                suffix += 1
                id = "\(base)-\(suffix)"
            }
            used.insert(id)
            return question.identified(as: id)
        }
    }

    // MARK: The ladder

    /// The Khan ladder over the lectures that have something to quiz, in
    /// course order: a practice quiz after each, a checkpoint where a topic
    /// ends, about every `checkpointEvery` of them (`checkpointGroups`), and
    /// the course test after the last. A course of `checkpointEvery`
    /// lectures or fewer gets no checkpoints: the test already covers them
    /// all.
    static func ladder(
        courseID: String,
        lectures: [(id: String, title: String)],
        checkpointEvery: Int = defaultCheckpointEvery,
        includeTest: Bool = true
    ) -> [CourseQuizSlot] {
        guard !lectures.isEmpty else { return [] }
        let every = min(max(checkpointEvery, checkpointEveryRange.lowerBound), checkpointEveryRange.upperBound)
        var slots: [CourseQuizSlot] = lectures.map { lecture in
            CourseQuizSlot(
                id: practiceID(courseID: courseID, lectureID: lecture.id),
                kind: .practice,
                title: "Quiz: \(lecture.title)",
                lectureIDs: [lecture.id],
                afterLectureID: lecture.id
            )
        }
        if lectures.count > every {
            for (index, group) in checkpointGroups(lectures, every: every).enumerated() {
                let ids = group.map(\.id)
                slots.append(CourseQuizSlot(
                    id: checkpointID(courseID: courseID, lectureIDs: ids),
                    kind: .checkpoint,
                    title: "Quiz \(index + 1)",
                    lectureIDs: ids,
                    afterLectureID: ids.last
                ))
            }
        }
        if includeTest {
            slots.append(CourseQuizSlot(
                id: testID(courseID: courseID),
                kind: .test,
                title: "Course test",
                lectureIDs: lectures.map(\.id),
                afterLectureID: lectures.last?.id
            ))
        }
        return slots
    }

    /// The lectures each checkpoint covers, in course order. A checkpoint
    /// closes a topic rather than counting to `every` (product owner, 2026-09-28:
    /// after "Isolated Mitochondria … 1", "2" and "3", not in the middle of
    /// "Mitochondrial Ion Transport 1" to "4"). The parts of a series stay
    /// under one checkpoint, and neighbouring series and lone lectures share
    /// one while together they are `every` lectures or fewer; a lecture left
    /// on its own joins the smaller neighbour. A series longer than half
    /// again `every`, and a run of lectures that are no series, are cut
    /// every `every` lectures. A course whose titles hold no series, or one
    /// series through the whole course ("Lecture 1" to "Lecture 18"), is cut
    /// every `every` lectures throughout, the ladder it always had.
    static func checkpointGroups(
        _ lectures: [(id: String, title: String)],
        every: Int
    ) -> [[(id: String, title: String)]] {
        let topics = lectures.map { lectureSeriesTopic($0.title) }
        var runs: [[(id: String, title: String)]] = []
        for (index, lecture) in lectures.enumerated() {
            if index > 0, let topic = topics[index], topic == topics[index - 1] {
                runs[runs.count - 1].append(lecture)
            } else {
                runs.append([lecture])
            }
        }
        guard runs.count > 1, runs.contains(where: { $0.count > 1 }) else {
            return everyFew(lectures, every: every)
        }

        var units: [[(id: String, title: String)]] = []
        var loose: [(id: String, title: String)] = []
        for run in runs {
            guard run.count > 1 else {
                loose.append(contentsOf: run)
                continue
            }
            units += everyFew(loose, every: every)
            loose = []
            units += run.count > every + every / 2 ? everyFew(run, every: every) : [run]
        }
        units += everyFew(loose, every: every)

        var groups: [[(id: String, title: String)]] = []
        for unit in units {
            if let last = groups.last, last.count + unit.count <= every {
                groups[groups.count - 1].append(contentsOf: unit)
            } else {
                groups.append(unit)
            }
        }
        var index = 0
        while groups.count > 1, index < groups.count {
            guard groups[index].count == 1 else {
                index += 1
                continue
            }
            let before = index > 0 ? groups[index - 1].count : Int.max
            let after = index + 1 < groups.count ? groups[index + 1].count : Int.max
            if before <= after {
                groups[index - 1].append(contentsOf: groups[index])
            } else {
                groups[index + 1].insert(contentsOf: groups[index], at: 0)
            }
            groups.remove(at: index)
        }
        return groups
    }

    /// `lectures` cut every `every`, a trailing group of one joining the
    /// group before it.
    private static func everyFew(
        _ lectures: [(id: String, title: String)],
        every: Int
    ) -> [[(id: String, title: String)]] {
        var groups: [[(id: String, title: String)]] = stride(from: 0, to: lectures.count, by: every).map {
            Array(lectures[$0..<min($0 + every, lectures.count)])
        }
        if groups.count > 1, let last = groups.last, last.count == 1 {
            groups.removeLast()
            groups[groups.count - 1].append(contentsOf: last)
        }
        return groups
    }

    /// The topic a lecture's title names, without the course's numbering and
    /// without which part of a series it is: "8) Mitochondrial Ion
    /// Transport 1", "Mitochondrial Ion Transport, Part II" and
    /// "Mitochondrial Ion Transport (3 of 4)" all name "mitochondrial ion
    /// transport", and "7) Parallelism" and "8) Parallelism" both name
    /// "parallelism". Nil when all that is left is a word like "Lecture":
    /// that is the course counting, not a topic.
    static func lectureSeriesTopic(_ title: String) -> String? {
        var topic = leadingLectureNumber.stringByReplacingMatches(
            in: title, range: NSRange(title.startIndex..., in: title), withTemplate: ""
        )
        topic = trailingPartNumber.stringByReplacingMatches(
            in: topic, range: NSRange(topic.startIndex..., in: topic), withTemplate: ""
        )
        topic = topic.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !topic.isEmpty, !countingWords.contains(topic) else { return nil }
        return topic
    }

    /// "12) ", "3. ", "Lecture 4: ", "Week 2 – " before the topic.
    private static let leadingLectureNumber = try! NSRegularExpression(
        pattern: #"^\s*(?i:(?:lecture|lec|lesson|session|class|week|module|unit|chapter|episode|day|video|talk)\.?\s*)?\d+\s*[).:\-–—]\s*"#
    )
    /// " 2", ", Part II", " (3 of 4)", " - Pt. 1", " 2/3" after it. Roman
    /// numerals only in capitals, so a title ending in a word is left whole.
    private static let trailingPartNumber = try! NSRegularExpression(
        pattern: #"[\s,:\-–—(]+(?:(?i:part|pt|session|lecture|lec|no|number|#)\.?\s*)?(?:\d{1,2}|[IVX]{1,4})(?:\s*(?:(?i:of)|/)\s*\d{1,2})?\s*\)?\s*$"#
    )
    private static let countingWords: Set<String> = [
        "lecture", "lec", "lesson", "session", "class", "week", "module", "unit",
        "chapter", "part", "episode", "day", "video", "talk", "seminar",
    ]

    /// About how many questions the material needs, a guide the writer may
    /// exceed when the material teaches more: a practice quiz follows the
    /// lecture quiz's pace; a checkpoint asks about four per lecture; the test
    /// about three, with at least twelve.
    static func questionCount(for kind: CourseQuiz.Kind, parts: [CourseQuizPart]) -> Int {
        let lectures = parts.filter { $0.reading == nil }
        let readings = parts.count - lectures.count
        switch kind {
        case .practice:
            let timed = lectures.first?.lines.compactMap(\.seconds) ?? []
            let span = timed.count >= 2 ? (timed.last ?? 0) - (timed.first ?? 0) : nil
            return LectureQuizPlanning.targetQuestionCount(spanSeconds: span)
        case .checkpoint:
            return min(maximumQuestionsPerQuiz, max(10, lectures.count * 4 + readings * 2))
        case .test:
            return min(maximumQuestionsPerQuiz, max(12, lectures.count * 3 + readings))
        }
    }

    // MARK: Readings

    /// A reading's practice questions come from a pass of their own, after
    /// the lecture's (docs/lecture-quiz-design.md, "Readings"): at most this
    /// many from one reading, on top of the lecture's.
    static let maximumQuestionsPerReading = 40
    /// A practice quiz never keeps more than this, however many readings.
    static let maximumPracticeQuestions = 150

    /// About one question per 1,500 characters of a reading, three to
    /// forty: a textbook page of some 3,000 characters teaches two points or
    /// more. Like the lecture's count, it is the least the reading needs;
    /// the writer's list of learning points decides.
    static func readingQuestionCount(for part: CourseQuizPart) -> Int {
        let characters = part.lines.reduce(0) { $0 + $1.text.count }
        return min(maximumQuestionsPerReading, max(3, Int((Double(characters) / 1_500).rounded())))
    }

    /// The most questions a practice quiz with these readings keeps: the
    /// lecture's own limit, and each reading's on top.
    static func practiceQuestionLimit(readings: Int) -> Int {
        min(maximumPracticeQuestions, LectureQuizPlanning.maximumQuestions + readings * maximumQuestionsPerReading)
    }

    /// The lines of a reading's source on its pages, or all of them when it
    /// is read whole. Nil when the pages cannot be told from the text (it
    /// carries no page breaks) or none of them has text: a reading is never
    /// quizzed on pages the plan did not choose.
    static func readingLines(_ lines: [LectureQuizLine], pages: ClosedRange<Int>?) -> [LectureQuizLine]? {
        guard let pages else { return lines.isEmpty ? nil : lines }
        let kept = lines.filter { line in line.page.map { pages.contains($0) } ?? false }
        return kept.isEmpty ? nil : kept
    }

    // MARK: Coverage

    /// The learning points a draft lists that no question it kept tests, by
    /// their numbers counting from 1, in order. A question counts only when
    /// the checks would keep it: its part and last line are in the material
    /// and it has a question and an answer. A draft that lists no points
    /// leaves nothing to check.
    static func uncoveredPoints(in draft: CourseQuizDraft, parts: [CourseQuizPart]) -> [Int] {
        let points = (draft.learningPoints ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !points.isEmpty else { return [] }
        let lineNumbers = parts.map { Set($0.lines.map(\.number)) }
        var covered: Set<Int> = []
        for raw in draft.questions {
            let partIndex = (raw.part ?? 1) - 1
            guard lineNumbers.indices.contains(partIndex),
                  lineNumbers[partIndex].contains(raw.lastLine),
                  !raw.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !raw.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            covered.formUnion(raw.points ?? [])
        }
        return points.indices.map { $0 + 1 }.filter { !covered.contains($0) && !points[$0 - 1].isEmpty }
    }

    // MARK: Material

    /// A source's stored text as numbered lines: the transcript blocks the
    /// reader shows, with their times when the transcript is timed. Plain text
    /// (notes, a written lesson) splits into its paragraphs the same way. A
    /// PDF's text, which keeps its page breaks, splits page by page
    /// (`pagedLines`), so each line knows its page.
    static func lines(from content: String) -> [LectureQuizLine] {
        if content.contains(PDFPageMarkers.formFeed) { return pagedLines(from: content) }
        let transcript = YouTubeSlideContentParser.parse(content).transcriptContent
        return YouTubeTranscriptDisplayParser.parse(transcript).segments.enumerated().map { offset, segment in
            LectureQuizLine(
                number: offset + 1,
                seconds: YouTubeTranscriptTime.seconds(from: segment.startTime),
                text: segment.text
            )
        }
    }

    /// Sentences kept together on one line of a paged text: the transcript
    /// parser's own chunk, four sentences or about ninety-five words.
    static let pagedLineSentences = 4
    static let pagedLineWords = 95
    private static let sentenceBreak = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)

    /// A PDF's stored text as numbered lines, page by page: the text between
    /// two page breaks (form feeds, `PDFTextExtractor.embeddedText`) is page
    /// N, counted from 1 within the source the way the Reader and a reading's
    /// pages count them, and each page is cut into runs of a few sentences.
    /// A book chapter's text keeps almost no paragraph breaks, so read as a
    /// transcript it would be three lines of thirty thousand characters. No
    /// line crosses a page, so a question's first line names its page.
    static func pagedLines(from content: String) -> [LectureQuizLine] {
        var lines: [LectureQuizLine] = []
        let pages = content.split(separator: PDFPageMarkers.formFeed, omittingEmptySubsequences: false)
        for (index, page) in pages.enumerated() {
            let text = page.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let sentences = sentenceBreak.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\u{0}")
                .components(separatedBy: "\u{0}")
                .filter { !$0.isEmpty }
            var current: [String] = []
            var words = 0
            func flush() {
                guard !current.isEmpty else { return }
                lines.append(LectureQuizLine(
                    number: lines.count + 1,
                    seconds: nil,
                    text: current.joined(separator: " "),
                    page: index + 1
                ))
                current = []
                words = 0
            }
            for sentence in sentences {
                current.append(sentence)
                words += sentence.split(separator: " ").count
                if current.count >= pagedLineSentences || words >= pagedLineWords { flush() }
            }
            flush()
        }
        return lines
    }

    /// Lines spread evenly through a part when all of it will not fit, so a
    /// course test samples the whole of each lecture instead of its opening.
    /// Line numbers are kept, so an answer still names real lines.
    static func sampledLines(_ lines: [LectureQuizLine], budget: Int) -> (lines: [LectureQuizLine], truncated: Bool) {
        let total = lines.reduce(0) { $0 + $1.text.count + 12 }
        guard total > budget, !lines.isEmpty else { return (lines, false) }
        let keepFraction = Double(budget) / Double(total)
        var kept: [LectureQuizLine] = []
        var credit = 0.0
        for line in lines {
            credit += keepFraction
            if credit >= 1 {
                credit -= 1
                kept.append(line)
            }
        }
        return (kept.isEmpty ? [lines[0]] : kept, true)
    }

    /// The material as a writer reads it: each part titled, each line
    /// labelled `[p.n]`, `[p.n · m:ss]` or, in a reading, `[p.n · p.5]`. A
    /// reading's part is titled with its lecture and where it is in the book.
    /// The budget is shared between the parts, none taking more than
    /// `maximumPartCharacters`.
    static func materialBlock(_ parts: [CourseQuizPart], budget: Int = materialCharacterBudget) -> (text: String, truncated: Bool) {
        guard !parts.isEmpty else { return ("", false) }
        let perPart = min(maximumPartCharacters, max(2_000, budget / parts.count))
        var truncated = false
        var blocks: [String] = []
        for (offset, part) in parts.enumerated() {
            let number = offset + 1
            let (lines, cut) = sampledLines(part.lines, budget: perPart)
            truncated = truncated || cut
            let title = part.reading.map { "Reading with \(part.lectureTitle): \($0.title) (\($0.place))" } ?? part.lectureTitle
            var block = ["Part \(number): \(title)\(cut ? " (excerpts)" : "")"]
            for line in lines {
                block.append("[\(number).\(line.label)] \(line.text)")
            }
            if let slides = CourseQuizPictures.block(part.slides, heading: "Slides of part \(number):", budget: perPart / 4) {
                block.append(slides)
            }
            if let figures = CourseQuizPictures.figureBlock(part.figures, heading: "Figures of part \(number):", budget: perPart / 4) {
                block.append(figures)
            }
            blocks.append(block.joined(separator: "\n"))
        }
        return (blocks.joined(separator: "\n\n"), truncated)
    }

    /// Checks a draft against the material. A question naming a part or a
    /// last line that is not there is dropped rather than guessed at, a first
    /// line out of range narrows to the last line, and two questions at the
    /// same level on the same line of the same part keep the first (a recall
    /// question and a problem built on the same lines are both kept). The
    /// rest come back basics first, as a problem set runs: by level, then in
    /// course order within a level. A question with no level the checks know
    /// comes first, so a draft written without levels keeps plain course
    /// order. Each is named by what it asks (`identified`), keeping the id of
    /// the same question in `previous`, the quiz being rewritten, and the
    /// picture that one had in the image store. At most `drawingLimit`
    /// drawings stay briefed, the first in order.
    static func questions(
        from draft: CourseQuizDraft,
        parts: [CourseQuizPart],
        limit: Int = maximumQuestionsPerQuiz,
        previous: [CourseQuizQuestion] = [],
        drawingLimit: Int = CourseQuizPictures.maximumDrawingsPerQuiz
    ) -> [CourseQuizQuestion] {
        let indexed = parts.map { part in
            Dictionary(part.lines.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var timelines: [Int: LectureQuizTimeline] = [:]
        func timeline(_ partIndex: Int) -> LectureQuizTimeline {
            if let known = timelines[partIndex] { return known }
            let made = LectureQuizTimeline(parts[partIndex].lines)
            timelines[partIndex] = made
            return made
        }
        var used: Set<String> = []
        var kept: [(rank: Int, part: Int, line: Int, question: CourseQuizQuestion)] = []
        for raw in draft.questions {
            let partIndex = (raw.part ?? 1) - 1
            guard indexed.indices.contains(partIndex) else { continue }
            let byNumber = indexed[partIndex]
            let question = raw.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = raw.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let level = raw.level
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap(CourseQuizQuestion.Level.init(rawValue:))
            let usedKey = "\(partIndex):\(raw.lastLine):\(level?.rawValue ?? "")"
            guard !question.isEmpty, !answer.isEmpty,
                  byNumber[raw.lastLine] != nil,
                  !used.contains(usedKey) else { continue }
            let firstLine = raw.firstLine.flatMap { first in
                byNumber[first] != nil && first <= raw.lastLine ? first : nil
            } ?? raw.lastLine
            let keyPoints = (raw.keyPoints ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let quote = raw.quote?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Rewatch opens where the lecture says the quote, not at the
            // start of the block it is in; without one, at the stretch.
            let quoteSeconds = quote.flatMap { quote in
                timeline(partIndex).seconds(saying: quote, within: firstLine...raw.lastLine)
            }
            used.insert(usedKey)
            kept.append((level?.rank ?? -1, partIndex, raw.lastLine, CourseQuizQuestion(
                id: "",
                sourceID: parts[partIndex].sourceID,
                firstLine: firstLine,
                lastLine: raw.lastLine,
                startSeconds: quoteSeconds ?? byNumber[firstLine]?.seconds,
                question: question,
                answer: answer,
                keyPoints: keyPoints,
                quote: quote?.isEmpty == false ? quote : nil,
                levelName: level?.rawValue,
                picture: CourseQuizPictures.picture(for: raw, in: parts[partIndex]),
                page: byNumber[firstLine]?.page
            )))
        }
        let ordered = kept.sorted { ($0.rank, $0.part, $0.line) < ($1.rank, $1.part, $1.line) }.prefix(limit)
        let named = identified(ordered.map { $0.question }, previous: previous)
        return CourseQuizPictures.limitingDrawings(
            CourseQuizPictures.keepingStoredPictures(named, from: previous),
            to: drawingLimit
        )
    }

    /// The questions with each one's moment where its lecture says its quote
    /// (`LectureQuizTimeline`), from the numbered lines of its source, keyed
    /// by source ID. A quiz saved before 2026-09-28 was timed at the start of
    /// its quote's block, or an assistant's reading of it, a median 23 s
    /// early; retiming it when it is opened puts every stored quiz right on
    /// every Mac without rewriting the synced record. A question keeps its
    /// stored time when it has no quote, its source is untimed, or the quote
    /// is not in the lines it rests on.
    static func timedByQuotes(
        _ questions: [CourseQuizQuestion],
        lines: [String: [LectureQuizLine]]
    ) -> [CourseQuizQuestion] {
        var timelines: [String: LectureQuizTimeline] = [:]
        return questions.map { question in
            guard let sourceID = question.sourceID, let quote = question.quote,
                  let sourceLines = lines[sourceID] else { return question }
            let timeline = timelines[sourceID] ?? LectureQuizTimeline(sourceLines)
            timelines[sourceID] = timeline
            let stretch = question.lastLine.map { last in min(question.firstLine ?? last, last)...last }
            guard let seconds = timeline.seconds(saying: quote, within: stretch) else { return question }
            var timed = question
            timed.startSeconds = seconds
            return timed
        }
    }

    // MARK: Outline

    /// The stretch of a part a question rests on, for the grader and Memory.
    static func coveredLines(for question: CourseQuizQuestion, in lines: [LectureQuizLine]) -> [LectureQuizLine] {
        guard let last = question.lastLine else { return [] }
        let first = question.firstLine ?? last
        return lines.filter { $0.number >= first && $0.number <= last }
    }

    /// Passages a Memory item for this question may be anchored to, best
    /// first: the writer's quote, then the opening words of each covered line.
    static func memoryExcerpts(for question: CourseQuizQuestion, in lines: [LectureQuizLine]) -> [String] {
        var excerpts: [String] = []
        if let quote = question.quote { excerpts.append(quote) }
        for line in coveredLines(for: question, in: lines).reversed() {
            let words = line.text.split(whereSeparator: \.isWhitespace)
            guard words.count >= 4 else { continue }
            excerpts.append(words.prefix(10).joined(separator: " "))
        }
        return excerpts
    }

    /// A question as the Memory item an answer to it is recorded on
    /// (`KnowledgeStore.recordSourceQuestionAttempt`), wherever it was
    /// answered: step `course-quiz-<quizID>-<questionID>`, anchored by
    /// `memoryExcerpts`. The item's id folds in the step and the question's
    /// words, and the question's id is what it asks (`questionID`), so the
    /// item follows the question, not its place in the quiz. Nil when the
    /// question names no source to anchor it to.
    static func memoryQuestion(
        quizID: String,
        question: CourseQuizQuestion,
        lines: [LectureQuizLine]
    ) -> SourceMemoryQuestion? {
        guard let sourceID = question.sourceID else { return nil }
        var memoryQuestion = SourceMemoryQuestion(
            sourceID: sourceID,
            stepID: "course-quiz-\(quizID)-\(question.id)",
            question: question.question,
            answer: question.answer,
            keyPoints: question.keyPoints,
            excerpts: memoryExcerpts(for: question, in: lines),
            origin: .courseQuiz
        )
        // Its picture, on the side the quiz shows it: a picture still
        // waiting to be drawn has no address yet, and the card goes without.
        if let picture = question.picture,
           let image = MemoryCardImage(target: picture.image, alt: picture.caption ?? "Picture") {
            switch picture.placement {
            case .question: memoryQuestion.frontImages = [image]
            case .answer: memoryQuestion.backImages = [image]
            }
        }
        return memoryQuestion
    }
}
