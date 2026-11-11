import SwiftUI

// A course on the phone: the Mac's course page (docs/courses-design.md) as a
// list, with the same checks, locks and Continue, and its quizzes taken here
// one question at a time. A sitting is graded on the learner's chat model,
// the way the Mac's quiz chat grades on the chat's own, and its score is the
// same synced row the Mac keeps (`courseQuiz.score.<quizID>`), so completing
// it on the phone opens the lectures after it on the Mac too.

// MARK: - Scores

/// The latest sitting of each quiz the course page has shown, read from and
/// written to the account's synced preference rows.
@MainActor
final class MobileCourseQuizScoreStore: ObservableObject {
    static let shared = MobileCourseQuizScoreStore()

    /// By synced key (`MobileCoursePathRow.scoreKeys`).
    @Published private(set) var scores: [String: LectureQuizScore] = [:]

    func load(keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let fetched = try await MobileModelPreferenceStore.shared.lectureQuizScores(forKeys: keys)
        for key in keys { scores[key] = fetched[key] }
    }

    /// Keeps a finished sitting as the quiz's score. The rows are read again
    /// first, so a pass made on the Mac since the page loaded is kept: a
    /// worse retake never takes a pass back (`LectureQuizScore.recorded`).
    func record(_ score: LectureQuizScore, for row: MobileCoursePathRow) async throws -> LectureQuizScore {
        guard let quiz = row.quiz else { return score }
        try await load(keys: row.scoreKeys)
        let previous = row.scoreKeys.lazy.compactMap { self.scores[$0] }.first
        let kept = score.recorded(after: previous)
        let key = LectureQuizScore.preferenceKey(courseQuizID: quiz.id)
        try await MobileModelPreferenceStore.shared.setLectureQuizScore(kept, forKey: key)
        scores[key] = kept
        return kept
    }
}

// MARK: - Course page

/// One course: its progress and Continue, then a section per lecture with
/// its video, readings, materials and practice quiz, the checkpoints and the
/// course test between them, and what no lecture claims at the end.
struct MobileCoursePageScreen: View {
    let courseID: String

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var scoreStore = MobileCourseQuizScoreStore.shared
    @State private var reviewedSourceIDs: Set<String> = []
    @State private var loadError: String?
    @State private var lockedMessage: String?
    @State private var quizToTake: MobileCoursePathRow?
    @State private var continueSource: MobileCloudSource?
    /// The course's quizzes, read from their Quiz records and `questions` satellites when
    /// the page opens (docs/cloudkit-schema-design.md §3.5.11); the catalog's course carries none.
    @State private var satelliteQuizzes: [CourseQuiz]?

    private var course: MobileCloudCourse? {
        guard var course = vm.collections.coursesByID[courseID] else { return nil }
        if let satelliteQuizzes { course.quizzes = satelliteQuizzes }
        return course
    }

    var body: some View {
        Group {
            if let course {
                let path = MobileCoursePath.build(course: course, sources: MobileSourceListing.listed(vm.allSources))
                let progress = MobileCourseProgress(scores: scoreStore.scores, reviewedSourceIDs: reviewedSourceIDs)
                content(path: path, progress: progress)
                    .task(id: path.quizRows.flatMap(\.scoreKeys)) { await loadProgress(path: path) }
            } else {
                ContentUnavailableView(
                    "Course not synced",
                    systemImage: "graduationcap",
                    description: Text("This course has not reached this phone yet. Pull to refresh once your Mac has synced.")
                )
            }
        }
        .navigationTitle(course?.title ?? "Course")
        .navigationBarTitleDisplayMode(.inline)
        // Again when the course arrives or its lessons change: a page opened before the catalog held the course
        // has no quizzes to list until the load runs against the course.
        .task(id: satelliteQuizzesKey) { await loadSatelliteQuizzes() }
        .alert("Locked", isPresented: Binding(
            get: { lockedMessage != nil },
            set: { if !$0 { lockedMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lockedMessage ?? "")
        }
        .fullScreenCover(item: $quizToTake) { row in
            if let quiz = row.quiz {
                MobileCourseQuizSittingView(row: row, quiz: quiz, courseTitle: course?.title ?? "Course")
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { continueSource != nil },
            set: { if !$0 { continueSource = nil } }
        )) {
            if let continueSource {
                MobileSourceReaderView(source: continueSource)
            }
        }
    }

    /// What the quizzes load depends on: empty until the catalog holds the course, then the course and its
    /// lessons in order.
    private var satelliteQuizzesKey: [String] {
        MobileCourseQuizzes.loadKey(courseID: courseID, course: vm.collections.coursesByID[courseID])
    }

    private func loadSatelliteQuizzes() async {
        guard let satellites = await MobileSatellites.current(),
              let lessons = vm.collections.coursesByID[courseID]?.lectures.map(\.id) else { return }
        satelliteQuizzes = await MobileCourseQuizzes.load(courseID: courseID, lessonOrder: lessons, satellites: satellites)
    }

    @ViewBuilder
    private func content(path: MobileCoursePath, progress: MobileCourseProgress) -> some View {
        let gate = progress.gate(for: path)
        List {
            Section {
                header(path: path, progress: progress, gate: gate)
            } footer: {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
            }

            ForEach(path.blocks) { block in
                switch block {
                case .unit(let unit):
                    Section {
                        ForEach(unit.rows) { row in
                            rowView(row, path: path, gate: gate, progress: progress)
                        }
                        if unit.rows.isEmpty {
                            Text("Nothing filed under this lecture yet.")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    } header: {
                        unitHeader(unit, gate: gate)
                    }
                case .milestone(let row):
                    Section {
                        rowView(row, path: path, gate: gate, progress: progress, isMilestone: true)
                    }
                }
            }

            if !path.furtherMaterial.isEmpty {
                Section("Further reading") {
                    ForEach(path.furtherMaterial) { source in
                        NavigationLink {
                            MobileSourceReaderView(source: source)
                        } label: {
                            MobileCoursePathRowLabel(
                                title: source.title,
                                detail: source.citationSubtitle,
                                leading: .source(source),
                                quizScore: nil,
                                state: .open,
                                tracksCompletion: false,
                                isNext: false,
                                isMilestone: false
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.load(forceRefresh: true)
            await loadProgress(path: path)
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(path: MobileCoursePath, progress: MobileCourseProgress, gate: CourseGate) -> some View {
        let rows = path.rows
        let counted = rows.filter { gate.tracksCompletion(of: $0) }
        let finished = counted.filter { gate.state(of: $0) == .finished }
        let lectures = rows.filter { if case .video = $0.kind { return true }; return false }
        let quizzes = path.quizRows
        let next = gate.nextEntryID.flatMap { id in rows.first { $0.id == id } }
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            if !counted.isEmpty {
                ProgressView(value: Double(finished.count), total: Double(counted.count))
                    .tint(next == nil ? .green : .accentColor)
                Text([
                    lectures.isEmpty ? nil : "\(lectures.filter { gate.state(of: $0) == .finished }.count) of \(lectures.count) lectures",
                    quizzes.isEmpty ? nil : "\(quizzes.filter { gate.state(of: $0) == .finished }.count) of \(quizzes.count) quizzes completed",
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let next {
                let started = rows.contains { row in
                    gate.state(of: row) == .finished || progress.score(for: row) != nil
                }
                Button {
                    open(next)
                } label: {
                    Label(started ? "Continue" : "Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course.continue")
                Text(continueName(next))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !counted.isEmpty {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                Text("Nothing on this course has synced to this phone yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
    }

    private func unitHeader(_ unit: MobileCourseUnit, gate: CourseGate) -> some View {
        let counted = unit.rows.filter { gate.tracksCompletion(of: $0) }
        let finished = counted.filter { gate.state(of: $0) == .finished }.count
        let locked = !unit.rows.isEmpty && unit.rows.allSatisfy { gate.state(of: $0).lockingQuizID != nil }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lecture \(unit.lecture.number)")
                    .font(.caption2.weight(.semibold))
                Text(unit.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(locked ? .secondary : .primary)
                    .textCase(nil)
            }
            Spacer(minLength: MobileDesign.Spacing.medium)
            if locked {
                Image(systemName: "lock.fill")
                    .accessibilityLabel("Locked")
            } else if !counted.isEmpty {
                Text("\(finished) of \(counted.count)")
                    .monospacedDigit()
                    .foregroundStyle(finished == counted.count ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            }
        }
    }

    // MARK: Rows

    private func rowView(
        _ row: MobileCoursePathRow,
        path: MobileCoursePath,
        gate: CourseGate,
        progress: MobileCourseProgress,
        isMilestone: Bool = false
    ) -> some View {
        rowControl(row, path: path, gate: gate, progress: progress, isMilestone: isMilestone)
            .listRowBackground(row.id == gate.nextEntryID ? Color.accentColor.opacity(0.10) : nil)
    }

    @ViewBuilder
    private func rowControl(
        _ row: MobileCoursePathRow,
        path: MobileCoursePath,
        gate: CourseGate,
        progress: MobileCourseProgress,
        isMilestone: Bool
    ) -> some View {
        let state = gate.state(of: row)
        let label = MobileCoursePathRowLabel(
            title: row.title,
            detail: detail(for: row, progress: progress),
            leading: leading(for: row, progress: progress),
            quizScore: progress.score(for: row),
            state: state,
            tracksCompletion: gate.tracksCompletion(of: row),
            isNext: row.id == gate.nextEntryID,
            isMilestone: isMilestone
        )
        if let quizID = state.lockingQuizID {
            // A locked row opens nothing: it says which quiz opens it.
            Button {
                let quizRow = path.quizRows.first { $0.quiz?.id == quizID }
                lockedMessage = "Opens once you complete \(quizRow.map(MobileCourseProgress.quizName) ?? "the quiz before it")."
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("course.row.locked")
        } else if let source = row.source {
            NavigationLink {
                MobileSourceReaderView(source: source)
            } label: {
                label
            }
            .accessibilityIdentifier("course.row.source")
        } else {
            Button {
                quizToTake = row
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("course.row.quiz")
        }
    }

    private func detail(for row: MobileCoursePathRow, progress: MobileCourseProgress) -> String? {
        switch row.kind {
        case .video(let source):
            return VideoWatchProgress(encoded: source.readingPositionLocator)?.displayLabel ?? source.subtitle
        case .material(let source, let role):
            if source.sourceType == "paper" {
                return ["Reading", source.citationSubtitle].compactMap { $0 }.joined(separator: " · ")
            }
            if source.sourceType == "book", role == "reading" { return "Reading" }
            return Self.roleLabel(role)
        case .quiz:
            return progress.quizDetail(for: row)
        }
    }

    private func leading(for row: MobileCoursePathRow, progress: MobileCourseProgress) -> MobileCoursePathRowLabel.Leading {
        switch row.kind {
        case .video(let source), .material(let source, _):
            return .source(source)
        case .quiz(let quiz):
            let symbol: String
            switch quiz.kind {
            case .practice: symbol = progress.score(for: row) != nil ? "checklist.checked" : "checklist"
            case .checkpoint: symbol = "flag"
            case .test: symbol = "flag.checkered"
            }
            return .quiz(symbol: symbol)
        }
    }

    /// The Mac's `CourseLectureItemRole` labels.
    private static func roleLabel(_ role: String) -> String {
        switch role {
        case "notes": return "Notes"
        case "slides": return "Slides"
        case "exercise": return "Exercise"
        case "reading": return "Reading"
        case "article": return "Article"
        case "podcast": return "Podcast"
        case "code": return "Code"
        case "reference": return "Reference"
        default: return "Material"
        }
    }

    private func continueName(_ row: MobileCoursePathRow) -> String {
        guard let quiz = row.quiz else { return row.title }
        switch quiz.kind {
        case .practice: return quiz.hasTopicTitle ? "Quiz · \(row.title)" : "Quiz · \(row.quizSubtitle ?? "")"
        case .checkpoint: return quiz.hasTopicTitle ? "Checkpoint · \(row.title)" : "\(row.title) · \(row.quizSubtitle ?? "")"
        case .test: return row.title
        }
    }

    private func open(_ row: MobileCoursePathRow) {
        if row.quiz != nil {
            quizToTake = row
        } else if let source = row.source {
            continueSource = source
        }
    }

    private func loadProgress(path: MobileCoursePath) async {
        reviewedSourceIDs = await MobileCloudSourceCatalog.shared.currentReviewedSourceIDs()
        do {
            try await scoreStore.load(keys: path.quizRows.flatMap(\.scoreKeys))
            loadError = nil
        } catch {
            // Without its scores the page cannot say what was completed or
            // passed, so it says so rather than showing every quiz as untaken.
            loadError = "Quiz scores could not be loaded from iCloud: \(error.localizedDescription)"
        }
    }
}

/// One row's content: what it is, its second line, and where it stands at
/// the trailing edge (the Mac's `CoursePathRow`): a green check once a source
/// is done, a score ring for a completed quiz, a lock while a quiz before it
/// is not yet completed, and an open ring otherwise.
struct MobileCoursePathRowLabel: View {
    enum Leading {
        case source(MobileCloudSource)
        case quiz(symbol: String)
    }

    let title: String
    let detail: String?
    let leading: Leading
    let quizScore: LectureQuizScore?
    let state: CourseStepState
    let tracksCompletion: Bool
    let isNext: Bool
    let isMilestone: Bool

    /// Done rows step back a little and locked ones further; the check and
    /// the lock stay at full strength.
    private var contentOpacity: Double {
        switch state {
        case .open: return 1
        case .finished: return 0.62
        case .locked: return 0.45
        }
    }

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            HStack(spacing: MobileDesign.Spacing.medium) {
                leadingView
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isMilestone ? .body.weight(.semibold) : .body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .opacity(contentOpacity)
            Spacer(minLength: MobileDesign.Spacing.small)
            trailing
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .source(let source):
            MobileSourceRowThumbnail(source: source)
        case .quiz(let symbol):
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 34)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .finished:
            if let quizScore {
                MobileCourseQuizScoreRing(score: quizScore)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            }
        case .locked:
            Image(systemName: "lock.fill")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Locked")
        case .open:
            if let quizScore {
                MobileCourseQuizScoreRing(score: quizScore)
            } else if tracksCompletion {
                Image(systemName: "circle")
                    .foregroundStyle(isNext ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .accessibilityLabel(isNext ? "Next" : "Not done")
            }
        }
    }
}

/// The phone's counterpart of the Mac course-row score ring.
private struct MobileCourseQuizScoreRing: View {
    let score: LectureQuizScore

    var body: some View {
        Group {
            if score.isFullyRight {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: score.fractionRight)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
                .animation(.easeInOut(duration: 0.2), value: score.right)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(score.right) of \(score.total) quiz questions right")
    }
}

// MARK: - Taking a quiz

enum MobileCourseQuizError: LocalizedError {
    case unusableGrade(model: String)

    var errorDescription: String? {
        switch self {
        case .unusableGrade(let model):
            return "\(model) did not send back a grade. Send your answer again, or pick another chat model in Settings."
        }
    }
}

/// One sitting of a course quiz: the stored questions in order, each answered
/// in the learner's own words and graded before the next. As in the Mac's
/// quiz chat there is no Show answer, and "I don't know" is an answer; a
/// first try on the right track but short gets one follow-up from the grader,
/// graded together with the reply. Skip moves on with no grade and without
/// the answer, and the question counts as not right.
@MainActor
final class MobileCourseQuizSitting: ObservableObject {
    enum Phase: Equatable {
        case answering
        case checking
        /// The grader's follow-up to the answer just given.
        case followUp(String)
        case graded(VideoQuizGrade)
        /// Every question graded; `saved` false while the score has not
        /// reached iCloud.
        case finished(LectureQuizScore, saved: Bool)
    }

    let row: MobileCoursePathRow
    let quiz: CourseQuiz
    @Published private(set) var index = 0
    @Published private(set) var phase: Phase = .answering
    @Published var draft = ""
    @Published private(set) var errorMessage: String?

    private var outcomes: [LectureQuizOutcome] = []
    /// The answer a follow-up asks the learner to finish.
    private var firstAnswer: String?
    private var textBySourceID: [String: String?] = [:]

    init(row: MobileCoursePathRow, quiz: CourseQuiz) {
        self.row = row
        self.quiz = quiz
    }

    var question: CourseQuizQuestion? {
        quiz.questions.indices.contains(index) ? quiz.questions[index] : nil
    }

    var skippedCount: Int { outcomes.filter { $0 == .skipped }.count }

    /// A question waiting for an answer, or for the reply to a follow-up.
    var canSkip: Bool {
        switch phase {
        case .answering, .followUp: return question != nil
        default: return false
        }
    }

    var canSubmit: Bool {
        switch phase {
        case .answering, .followUp:
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    func submit() async {
        guard canSubmit, let question else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attempt: QuizAnswerAttempt
        if case .followUp(let followUp) = phase, let firstAnswer {
            attempt = QuizAnswerAttempt(
                answer: firstAnswer,
                followUp: QuizAnswerAttempt.FollowUp(question: followUp, reply: text),
                learnerCanReply: true
            )
        } else {
            attempt = QuizAnswerAttempt(answer: text, learnerCanReply: true)
        }
        let before = phase
        phase = .checking
        errorMessage = nil
        do {
            switch try await grade(question, attempt: attempt) {
            case .followUp(let followUp):
                firstAnswer = text
                draft = ""
                phase = .followUp(followUp)
            case .graded(let grade):
                outcomes.append(.graded(grade.verdict))
                firstAnswer = nil
                draft = ""
                phase = .graded(grade)
            }
        } catch is CancellationError {
            phase = before
        } catch {
            // Nothing grades in the grader's place (AGENTS.md, AI tutor
            // failures): the answer stays in the box to send again.
            errorMessage = error.localizedDescription
            phase = before
        }
    }

    func next() async {
        guard case .graded = phase else { return }
        await advance()
    }

    /// Skip: no grade, and the question counts as not right. A draft or a
    /// follow-up waiting on it goes with it.
    func skip() async {
        guard canSkip else { return }
        outcomes.append(.skipped)
        firstAnswer = nil
        draft = ""
        errorMessage = nil
        // Held while a last question's score is kept, so a second tap cannot
        // skip twice.
        phase = .checking
        await advance()
    }

    private func advance() async {
        if index + 1 < quiz.questions.count {
            index += 1
            phase = .answering
        } else {
            await saveScore(LectureQuizScore(outcomes: outcomes))
        }
    }

    func saveScore(_ score: LectureQuizScore) async {
        errorMessage = nil
        do {
            let kept = try await MobileCourseQuizScoreStore.shared.record(score, for: row)
            phase = .finished(kept, saved: true)
        } catch {
            errorMessage = "Your score could not be saved to iCloud: \(error.localizedDescription)"
            phase = .finished(score, saved: false)
        }
    }

    func retake() {
        index = 0
        outcomes = []
        firstAnswer = nil
        draft = ""
        errorMessage = nil
        phase = .answering
    }

    private func grade(_ question: CourseQuizQuestion, attempt: QuizAnswerAttempt) async throws -> QuizGraderResult {
        let content = await sourceText(question.sourceID)
        let stretch = MobileCourseQuizStretch.text(for: question, in: content)
        let message = QuizGraderExchange.message(
            question: question.question,
            referenceAnswer: question.answer,
            keyPoints: question.keyPoints,
            coveredTranscript: String(stretch.prefix(12_000)),
            attempt: attempt
        )
        let usage = AIUsageSource(id: question.sourceID ?? quiz.id, type: "course", title: row.title)
        return try await AIUsageAttribution.withSource(usage, activityID: "mobile-course-quiz-\(quiz.id)") { () async throws -> QuizGraderResult in
            // An unreadable grade is asked for again, after 2 s and 4 s, as
            // the Mac's `QuizGrading` does; any other failure is reported.
            var model = "The chat model"
            for tryNumber in 1...3 {
                let result = try await MobileManagedTextCall.complete(
                    task: .chat,
                    system: Prompts.videoQuizGrader,
                    messages: [(role: "user", content: message)],
                    maxTokens: QuizGraderExchange.maxTokens,
                    jsonMode: true,
                    operation: "mobile_course_quiz_grading"
                )
                if let reply = QuizGraderReply(reply: result.text), let graded = reply.result(for: attempt) {
                    return graded
                }
                model = result.route.model
                if tryNumber < 3 { try await Task.sleep(for: .seconds(2 * tryNumber)) }
            }
            throw MobileCourseQuizError.unusableGrade(model: model)
        }
    }

    /// The lecture's text for the grader's stretch, loaded once per source.
    /// A source whose text cannot be loaded grades on its quote alone.
    private func sourceText(_ sourceID: String?) async -> String? {
        guard let sourceID else { return nil }
        if let cached = textBySourceID[sourceID] { return cached }
        let text = try? await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: sourceID)
        textBySourceID[sourceID] = text
        return text
    }
}

struct MobileCourseQuizSittingView: View {
    let row: MobileCoursePathRow
    let courseTitle: String

    @StateObject private var sitting: MobileCourseQuizSitting
    @StateObject private var dictation = MobileComposerDictation()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isAnswerFocused: Bool
    @State private var confirmsLeave = false

    init(row: MobileCoursePathRow, quiz: CourseQuiz, courseTitle: String) {
        self.row = row
        self.courseTitle = courseTitle
        _sitting = StateObject(wrappedValue: MobileCourseQuizSitting(row: row, quiz: quiz))
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .finished(let score, let saved) = sitting.phase {
                    results(score, saved: saved)
                } else if let question = sitting.question {
                    questionScreen(question)
                } else {
                    ContentUnavailableView("No questions", systemImage: "checklist")
                }
            }
            .navigationTitle(row.title == "Quiz" ? (row.quizSubtitle ?? "Quiz") : row.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if isUnderWay { confirmsLeave = true } else { dismiss() }
                    }
                }
                if sitting.canSkip {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Skip") {
                            isAnswerFocused = false
                            Task { await sitting.skip() }
                        }
                        .disabled(dictation.state == .listening)
                        .accessibilityHint("Goes on without answering. The question counts as not right.")
                        .accessibilityIdentifier("courseQuiz.skip")
                    }
                }
            }
            .confirmationDialog("Leave the quiz?", isPresented: $confirmsLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { dismiss() }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("A sitting left halfway is not kept. The quiz starts again from question 1 next time.")
            }
        }
        .task { await dictation.refreshAvailability() }
        .onDisappear { Task { await dictation.cancel() } }
        .interactiveDismissDisabled(isUnderWay)
    }

    private var isUnderWay: Bool {
        if case .finished = sitting.phase { return false }
        return sitting.index > 0 || sitting.phase != .answering
    }

    // MARK: Question

    private func questionScreen(_ question: CourseQuizQuestion) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                    ProgressView(value: Double(sitting.index), total: Double(max(1, sitting.quiz.questions.count)))
                    Text(questionHeading(question))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(question.question)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    switch sitting.phase {
                    case .followUp(let followUp):
                        bubble(followUp, systemImage: "questionmark.bubble", tint: .orange)
                    case .graded(let grade):
                        gradeCard(grade, question: question)
                    default:
                        EmptyView()
                    }

                    if let error = sitting.errorMessage {
                        bubble(error, systemImage: "exclamationmark.triangle", tint: .red)
                    }
                }
                .padding(MobileDesign.Spacing.large)
                .mobileReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)

            bottomBar
                .padding(.horizontal, MobileDesign.Spacing.medium)
                .padding(.vertical, MobileDesign.Spacing.small)
                .mobileReadableWidth()
        }
    }

    private func questionHeading(_ question: CourseQuizQuestion) -> String {
        var parts = ["Question \(sitting.index + 1) of \(sitting.quiz.questions.count)"]
        if let level = question.level { parts.append(level.displayName) }
        return parts.joined(separator: " · ")
    }

    private func gradeCard(_ grade: VideoQuizGrade, question: CourseQuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Label(verdictTitle(grade.verdict), systemImage: verdictSymbol(grade.verdict))
                .font(.headline)
                .foregroundStyle(verdictTint(grade.verdict))
            Text(grade.feedback)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Answer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdictTint(grade.verdict).opacity(0.08), in: RoundedRectangle(cornerRadius: MobileDesign.Radius.card, style: .continuous))
    }

    private func bubble(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .padding(MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: MobileDesign.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch sitting.phase {
        case .graded:
            Button {
                Task { await sitting.next() }
            } label: {
                Text(sitting.index + 1 < sitting.quiz.questions.count ? "Next Question" : "See Results")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("courseQuiz.next")
        default:
            composer
        }
    }

    private var composer: some View {
        let isChecking = sitting.phase == .checking
        let isListening = dictation.state == .listening
        return MobileComposerSurface {
            HStack(alignment: .bottom, spacing: MobileDesign.Spacing.xSmall) {
                TextField(placeholder, text: answerText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isAnswerFocused)
                    .disabled(isChecking || isListening)
                    .padding(.vertical, 7)
                    .accessibilityIdentifier("courseQuiz.answer")
                if dictation.isAvailable, !isChecking {
                    Button {
                        dictation.toggle { text in
                            let typed = sitting.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            sitting.draft = typed.isEmpty ? text : "\(typed) \(text)"
                        }
                    } label: {
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isListening ? Color.red : Color.secondary)
                            .frame(width: MobileDesign.Metrics.minimumTouchTarget, height: MobileDesign.Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isListening ? "Stop dictation" : "Dictate your answer")
                }
                if isChecking {
                    ProgressView()
                        .frame(width: MobileDesign.Metrics.minimumTouchTarget, height: MobileDesign.Metrics.minimumTouchTarget)
                        .accessibilityLabel("Checking your answer")
                } else {
                    Button {
                        isAnswerFocused = false
                        Task { await sitting.submit() }
                    } label: {
                        // The chat composers' disc, in the text's colour: this one was the
                    // only blue send button left in the app.
                    MobileComposerDiscLabel(systemImage: "arrow.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(!sitting.canSubmit || isListening)
                    .accessibilityLabel("Send answer")
                    .accessibilityIdentifier("courseQuiz.send")
                }
            }
        }
    }

    private var placeholder: String {
        if case .followUp = sitting.phase { return "Reply to the follow-up" }
        return "Your answer, in your own words"
    }

    private var answerText: Binding<String> {
        Binding(
            get: { dictation.state == .listening ? dictation.partialText : sitting.draft },
            set: { newValue in
                guard dictation.state != .listening else { return }
                sitting.draft = newValue
            }
        )
    }

    // MARK: Results

    private func results(_ score: LectureQuizScore, saved: Bool) -> some View {
        ScrollView {
            VStack(spacing: MobileDesign.Spacing.large) {
                Image(systemName: score.hasPassed ? "checkmark.seal.fill" : "arrow.counterclockwise.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(score.hasPassed ? .green : .orange)
                Text(score.label)
                    .font(.title.weight(.semibold))
                if sitting.skippedCount > 0 {
                    Text("\(sitting.skippedCount) skipped, counted as not right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(resultMessage(score))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let error = sitting.errorMessage {
                    bubble(error, systemImage: "exclamationmark.icloud", tint: .red)
                }
                if !saved {
                    Button("Save Score Again") {
                        Task { await sitting.saveScore(score) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(saved ? "Done" : "Close Without Saving") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Retake Quiz") { sitting.retake() }
            }
            .padding(MobileDesign.Spacing.xLarge)
            .mobileReadableWidth()
        }
    }

    private func resultMessage(_ score: LectureQuizScore) -> String {
        if score.passes { return "Completed and passed. What follows this quiz in \(courseTitle) is open." }
        if score.hasPassed { return "Completed. You passed this quiz before, and what follows it stays open." }
        return "Completed. What follows this quiz in \(courseTitle) is open; you can retake it any time."
    }

    private func verdictTitle(_ verdict: VideoQuizVerdict) -> String {
        switch verdict {
        case .correct: return "Right"
        case .partial: return "Partly right"
        case .incorrect: return "Not quite"
        }
    }

    private func verdictSymbol(_ verdict: VideoQuizVerdict) -> String {
        switch verdict {
        case .correct: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .incorrect: return "xmark.circle.fill"
        }
    }

    private func verdictTint(_ verdict: VideoQuizVerdict) -> Color {
        switch verdict {
        case .correct: return .green
        case .partial: return .orange
        case .incorrect: return .red
        }
    }
}
