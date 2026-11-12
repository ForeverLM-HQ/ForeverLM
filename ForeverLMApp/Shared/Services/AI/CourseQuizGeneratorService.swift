#if os(macOS)
import AppKit
import Foundation
import ImageIO
import os
import PDFKit

private let courseQuizWriterLogger = Logger(subsystem: "com.foreverlm", category: "CourseQuizWriter")

/// What to write for a course (docs/lecture-quiz-design.md).
struct CourseQuizGenerationOptions: Equatable, Sendable {
    var checkpointEvery: Int = CourseQuizPlanning.defaultCheckpointEvery
    var includeTest: Bool = true
    /// Rewrite quizzes that already exist instead of keeping them.
    var rewrite: Bool = false
    /// Only these quizzes of the ladder; nil for the whole ladder.
    var quizIDs: Set<String>? = nil
    /// Whether the writers may brief pictures for ForeverLM to draw where no
    /// slide or figure shows a question's point (at most
    /// `CourseQuizPictures.maximumDrawingsPerQuiz` a quiz). On by default:
    /// The product owner, 2026-09-27, by default try a picture for each question, drawn
    /// where no slide or figure shows it. The callers set it from Settings ›
    /// Images › Draw pictures for new quizzes (on unless turned off) and draw
    /// the briefs after the run with
    /// `drawQuestionPictures`; a run that will not draw turns it off rather
    /// than leave briefs waiting.
    var briefsDrawings: Bool = true
}

/// What a picture pass over quizzes already written did, quiz by quiz.
struct CourseQuizPictureResult: Sendable {
    enum Outcome: Sendable, Equatable {
        /// This many questions got a picture (a drawing briefed counts; the
        /// drawing itself is in `drawing`).
        case pictured(Int)
        /// The picker found no question a slide, a figure or a drawing helps.
        case noneFitting
        /// No question rests on a lecture video with captured slides or a
        /// reading with figures (and nothing may be drawn), or every one
        /// that does has a picture already.
        case nothingToPicture
        case failed(String)
    }

    let courseID: String
    /// Every quiz asked about, in outline order, with what happened to it.
    let outcomes: [(quiz: CourseQuiz, outcome: Outcome)]
    /// The pictures drawn for the briefs, after the picks.
    var drawing = CourseQuizDrawingResult()

    var picturedCount: Int {
        outcomes.reduce(0) { total, entry in
            if case .pictured(let count) = entry.outcome { return total + count }
            return total
        }
    }
}

/// What drawing the pictures briefed for quizzes' questions did.
struct CourseQuizDrawingResult: Sendable, Equatable {
    /// Pictures drawn and pinned, by quiz id.
    var drawn: [String: Int] = [:]
    /// Briefs still waiting after the run, by quiz id: past the run's limit,
    /// or stopped before they were drawn.
    var waiting: [String: Int] = [:]
    /// The first drawing that failed, by quiz id; the quiz's other briefs
    /// wait for the next run. The run's closing save that sends the pictures
    /// to the learner's other devices reports its failure here too.
    var failures: [String: String] = [:]

    var drawnCount: Int { drawn.values.reduce(0, +) }
}

/// The two stretches of a pass that gives existing quiz questions pictures.
/// Callers use this to show honest progress without guessing from pictures as
/// they happen to land in storage.
enum CourseQuizPicturePhase: String, Sendable {
    case choosing = "Choosing pictures"
    case drawing = "Drawing pictures"
}

struct CourseQuizGenerationResult: Sendable {
    struct Failure: Sendable {
        let slot: CourseQuizSlot
        let message: String
    }

    let courseID: String
    /// The ladder in outline order, as planned.
    let slots: [CourseQuizSlot]
    let written: [CourseQuiz]
    /// Quizzes that already existed and were left as they were.
    let kept: [String]
    /// Kept quizzes written before quizzes were named, named in this run.
    var named: [CourseQuiz] = []
    /// Checkpoints of the ladder not written because a stored checkpoint the
    /// ladder no longer has already asks about some of their lectures.
    var covered: [String] = []
    /// Stored checkpoints the ladder no longer has, removed by a rewrite
    /// once the ladder's checkpoints written in it covered their lectures.
    var retired: [CourseQuiz] = []
    let failed: [Failure]
    /// Lectures with nothing to quiz yet: no transcript or text stored.
    let lecturesWithoutMaterial: [(id: String, title: String)]
}

/// One course's lecture material, read from storage once.
struct CourseQuizMaterial: Sendable {
    let courseID: String
    let courseTitle: String?
    /// Lectures that can be quizzed, in course order.
    let parts: [CourseQuizPart]
    let subjects: [String: StudioArticle]
    let lecturesWithoutMaterial: [(id: String, title: String)]
    /// Each quizzable lecture's readings, in the order the lecture lists
    /// them: a part per reading, on its planned pages (`readingParts`).
    var readings: [String: [CourseQuizPart]] = [:]

    /// The parts a quiz over these lectures reads, in course order: each
    /// lecture, then its readings.
    func parts(forLectures lectureIDs: [String]) -> [CourseQuizPart] {
        let byLecture = Dictionary(parts.map { ($0.lectureID, $0) }, uniquingKeysWith: { first, _ in first })
        return lectureIDs.flatMap { id in
            byLecture[id].map { [$0] + (readings[id] ?? []) } ?? []
        }
    }
}

/// Writes a course's quizzes ahead of time: the Khan ladder of a practice quiz
/// after each lecture, a checkpoint after every few, and the course test. The
/// app's Write Quizzes action and the `generate_course_quizzes` MCP tool run
/// this same service, so a quiz is the same whoever asked for it. Each quiz is
/// saved as soon as it is written, so an interrupted run keeps what it wrote
/// and the next one writes only what is missing.
struct CourseQuizGeneratorService: Sendable {
    let storage: StorageService
    let aiService: AIService
    /// Quizzes written at once. Each is one model call, and the Background
    /// route serves them in parallel.
    static let concurrentWrites = 3

    /// The course's lectures that have text, each with the one source its
    /// questions rest on: the lecture's video, else its notes or written
    /// lesson, else any other item with text; and each lecture's readings.
    func material(courseID: String) async throws -> CourseQuizMaterial {
        let metadata = try await storage.loadCourseMetadata()
        let lectures = try await storage.loadCourseLectures()
            .filter { $0.courseName == courseID }
            .sorted { $0.number < $1.number }
        guard metadata[courseID] != nil || !lectures.isEmpty else {
            throw CourseQuizError.courseNotFound(courseID)
        }
        let lectureIDs = Set(lectures.map(\.id))
        let items = try await storage.loadCourseLectureItems().filter { lectureIDs.contains($0.lectureId) }
        let itemsByLecture = Dictionary(grouping: items, by: \.lectureId)
            .mapValues { $0.sorted { $0.sortIndex < $1.sortIndex } }
        let sourceIDs = Array(Set(items.compactMap(\.sourceId)))
        let articles = Dictionary(
            try await storage.loadPersistedSources(ids: sourceIDs).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // A reading's pages ride a source unit, and a source kept from AI is
        // never quizzed on (docs/textbook-readings-design.md).
        let hasReadings = items.contains { $0.role == .reading }
        let units = hasReadings ? try await storage.loadCourseSourceUnits() : [:]
        let excluded = hasReadings ? try await storage.knowledgeBoundaryExcludedSourceIDs() : []

        var parts: [CourseQuizPart] = []
        var subjects: [String: StudioArticle] = [:]
        var without: [(id: String, title: String)] = []
        var readings: [String: [CourseQuizPart]] = [:]
        for lecture in lectures {
            let lectureItems = itemsByLecture[lecture.id] ?? []
            let ranked = lectureItems.filter { $0.role == .video }
                + lectureItems.filter { $0.role == .notes }
                + lectureItems.filter { $0.role != .video && $0.role != .notes }
            var found: (article: StudioArticle, lines: [LectureQuizLine], slides: [CourseQuizSlide])?
            for item in ranked {
                guard let sourceID = item.sourceId, let article = articles[sourceID],
                      let content = await storage.loadSourceContent(sourceID),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let byMoment = YouTubeTranscriptService.isYouTubeURL(article.url)
                let (lines, slides) = await Task.detached(priority: .utility) {
                    (
                        CourseQuizPlanning.lines(from: content),
                        CourseQuizPictures.slides(from: content, sourceID: sourceID, byMoment: byMoment)
                    )
                }.value
                if lines.count >= LectureQuizPlanning.minimumLines {
                    found = (article, lines, slides)
                    break
                }
            }
            let title = Self.lectureTitle(lecture, fallback: ranked.compactMap { $0.sourceId.flatMap { articles[$0]?.title } }.first)
            guard let found else {
                without.append((lecture.id, title))
                continue
            }
            parts.append(CourseQuizPart(
                lectureID: lecture.id,
                lectureTitle: title,
                sourceID: found.article.id,
                lines: found.lines,
                slides: found.slides
            ))
            subjects[lecture.id] = found.article
            let lectureReadings = await readingParts(
                lectureID: lecture.id,
                lectureTitle: title,
                items: lectureItems.filter { $0.role == .reading && $0.sourceId != found.article.id },
                articles: articles,
                units: units,
                excluded: excluded
            )
            if !lectureReadings.isEmpty { readings[lecture.id] = lectureReadings }
        }
        return CourseQuizMaterial(
            courseID: courseID,
            courseTitle: metadata[courseID]?.title,
            parts: parts,
            subjects: subjects,
            lecturesWithoutMaterial: without,
            readings: readings
        )
    }

    /// A lecture's readings as parts of their own (docs/lecture-quiz-design.md,
    /// "Readings"): a textbook reading on the pages its plan chose, or a source
    /// filed under the lecture as its reading, read whole. A reading kept from
    /// AI is left out, and so is one whose pages cannot be found in its text,
    /// rather than quizzed on pages the plan did not choose.
    func readingParts(
        lectureID: String,
        lectureTitle: String,
        items: [CourseLectureItem],
        articles: [String: StudioArticle],
        units: [String: SourceUnit],
        excluded: Set<String>
    ) async -> [CourseQuizPart] {
        var parts: [CourseQuizPart] = []
        var seen: Set<String> = []
        for item in items {
            guard let sourceID = item.sourceId, !excluded.contains(sourceID),
                  let article = articles[sourceID] else { continue }
            let unit = item.sourceUnitId.flatMap { units[$0] }
            if item.sourceUnitId != nil, unit == nil { continue }
            let pages = unit.flatMap { $0.kind == TextbookReading.unitKind ? TextbookReading.pages(fromLocator: $0.locator) : nil }
            if unit != nil, pages == nil { continue }
            // The same pages twice under one lecture are one reading.
            let key = "\(sourceID):\(pages.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "all")"
            guard !seen.contains(key),
                  let content = await storage.loadSourceContent(sourceID),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let lines = await Task.detached(priority: .utility) {
                CourseQuizPlanning.readingLines(CourseQuizPlanning.lines(from: content), pages: pages)
            }.value
            guard let lines, lines.count >= LectureQuizPlanning.minimumLines else { continue }
            seen.insert(key)
            // The figures on the planned pages, for the writer to show with a
            // question as it shows a lecture's slides. Read off the file on
            // this Mac; a reading whose file is elsewhere lists none.
            let filePath = article.resolvedFileLocation
            let figures = await Task.detached(priority: .utility) {
                Self.readingFigures(sourceID: sourceID, filePath: filePath, pages: pages)
            }.value
            let sections = unit?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var place = article.title
            if let pages {
                place += pages.count == 1 ? ", page \(pages.lowerBound)" : ", pages \(pages.lowerBound)–\(pages.upperBound)"
            }
            parts.append(CourseQuizPart(
                lectureID: lectureID,
                lectureTitle: lectureTitle,
                sourceID: sourceID,
                lines: lines,
                figures: figures,
                reading: CourseQuizPartReading(
                    title: sections.isEmpty ? article.title : sections,
                    place: place,
                    pages: pages
                )
            ))
        }
        return parts
    }

    /// A reading's captioned figures on `pages` (every page when nil): for a
    /// PDF, each labelled figure on the page that shows it — which is not
    /// always its caption's page (`PDFTextExtractor.indexedFigures`) — cropped
    /// to its block of ink (`PaperFigureRectRefiner`, read off the page for
    /// free); for an EPUB chapter, its pictures with their captions. A PDF's figures are
    /// cropped from the page the figure is on, not its caption's, so a legend set
    /// a page away from its figure does not put a page of prose on the
    /// question. Empty when the file is not on this Mac or shows no figure.
    /// File and PDF work: never on the main actor.
    static func readingFigures(sourceID: String, filePath: String?, pages: ClosedRange<Int>?) -> [CourseQuizFigure] {
        guard let filePath else { return [] }
        // A book chapter's path names its pages of the book's file; its pages count from the chapter's first.
        let location = SourcePDFPages(stored: filePath)
        guard FileManager.default.isReadableFile(atPath: location.path) else { return [] }
        if URL(fileURLWithPath: location.path).pathExtension.lowercased() == "pdf" {
            guard let document = location.document(), document.pageCount > 0 else { return [] }
            // A PDFPage holds its document weakly; keep it while pages are read.
            return withExtendedLifetime(document) {
                let first = max(1, pages?.lowerBound ?? 1)
                let last = min(document.pageCount, pages?.upperBound ?? document.pageCount)
                guard first <= last else { return [] }
                let figures = PDFTextExtractor.indexedFigures(from: document, pages: (first - 1)..<last)
                let labelsPerPage = Dictionary(grouping: figures, by: \.pageIndex).mapValues(\.count)
                var found: [(reference: SourceImageReference, page: Int?, caption: String)] = []
                var labels: [String] = []
                for figure in figures.prefix(CourseQuizPictures.maximumFiguresPerPart) {
                    guard let page = document.page(at: figure.pageIndex) else { continue }
                    let crop = PaperFigureRectRefiner.figureCrop(
                        forCaption: figure.caption,
                        on: page,
                        sharesPageWithOtherFigures: (labelsPerPage[figure.pageIndex] ?? 1) > 1
                    )
                    found.append((
                        SourceImageReference(sourceID: sourceID, location: .page(figure.pageIndex + 1), crop: crop),
                        figure.pageIndex + 1,
                        figure.caption
                    ))
                    labels.append(figure.figureLabel)
                }
                var listed = CourseQuizPictures.figures(from: found)
                for index in listed.indices where index < labels.count {
                    listed[index].label = labels[index]
                }
                return listed
            }
        }
        guard EPUBParser.isMarkupChapter(filePath),
              let entries = try? SourceImageCatalog.entries(sourceID: sourceID, filePath: filePath, query: nil, page: nil) else {
            return []
        }
        // A picture the chapter names nothing for is decoration, not a figure.
        let named = entries.compactMap { entry -> (reference: SourceImageReference, page: Int?, caption: String)? in
            let caption = entry.caption.isEmpty ? entry.context : entry.caption
            return caption.isEmpty ? nil : (entry.reference, nil, caption)
        }
        return CourseQuizPictures.figures(from: named)
    }

    static func lectureTitle(_ lecture: CourseSession, fallback: String?) -> String {
        if let title = lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let fallback, !fallback.isEmpty { return fallback }
        return "Lecture \(lecture.number)"
    }

    /// The ladder for a course's material, before anything is written.
    static func ladder(for material: CourseQuizMaterial, options: CourseQuizGenerationOptions) -> [CourseQuizSlot] {
        CourseQuizPlanning.ladder(
            courseID: material.courseID,
            lectures: material.parts.map { ($0.lectureID, $0.lectureTitle) },
            checkpointEvery: options.checkpointEvery,
            includeTest: options.includeTest
        )
    }

    func run(
        courseID: String,
        options: CourseQuizGenerationOptions = CourseQuizGenerationOptions(),
        onProgress: @escaping @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> CourseQuizGenerationResult {
        let material = try await material(courseID: courseID)
        guard !material.parts.isEmpty else { throw CourseQuizError.nothingToQuiz }
        let slots = Self.ladder(for: material, options: options)
        let stored = try await storage.loadCourseQuizzes(courseID: courseID)
        let existing = Set(stored.map(\.id))
        // Checkpoints the ladder no longer has: written before its groups
        // moved (a lecture added, or checkpoints following lecture series).
        // They still ask about their lectures, so a run adds no second
        // checkpoint over any of them; a rewrite replaces them below.
        let ladderIDs = Set(slots.map(\.id))
        let offLadder = stored.filter { $0.kind == .checkpoint && !ladderIDs.contains($0.id) }
        let offLadderLectures = Set(offLadder.flatMap(\.lectureIDs))
        let covered = options.rewrite ? [] : slots.filter { slot in
            slot.kind == .checkpoint && !existing.contains(slot.id) && !offLadderLectures.isDisjoint(with: slot.lectureIDs)
        }.map(\.id)
        let wanted = slots.filter { slot in
            if let only = options.quizIDs, !only.contains(slot.id) { return false }
            if covered.contains(slot.id) { return false }
            return options.rewrite || !existing.contains(slot.id)
        }
        let kept = slots.map(\.id).filter { existing.contains($0) && !wanted.map(\.id).contains($0) }
        guard !wanted.isEmpty else {
            var result = CourseQuizGenerationResult(
                courseID: courseID, slots: slots, written: [], kept: kept, failed: [],
                lecturesWithoutMaterial: material.lecturesWithoutMaterial
            )
            result.covered = covered
            result.named = await nameUnnamedQuizzes(courseID: courseID, material: material, only: options.quizIDs)
            return result
        }
        // One config per task, resolved up front: a missing route fails the
        // whole run with its reason before anything is spent.
        let practiceConfig = wanted.contains { $0.kind == .practice }
            ? try Self.config(for: .lectureQuizWriting) : nil
        let courseConfig = wanted.contains { $0.kind != .practice }
            ? try Self.config(for: .courseQuizWriting) : nil
        // What the learner said about themselves, so questions meet them where
        // they are (docs/textbook-readings-design.md). Never part of a quiz's
        // identity: ids stay digests of the course and its lectures.
        let learnerContext = try await CourseLearnerContext.current(courseID: courseID, storage: storage).promptBlock

        var written: [CourseQuiz] = []
        var failed: [CourseQuizGenerationResult.Failure] = []
        var done = 0
        await onProgress(0, wanted.count)
        await withTaskGroup(of: (CourseQuizSlot, Result<CourseQuiz, Error>).self) { group in
            var pending = wanted[...]
            func startNext() {
                // Stopped (cancel_ai_work, or the sidebar's own task ending):
                // the quizzes in flight end on their cancelled requests, and
                // no new one is started to fail the same way.
                guard !Task.isCancelled, let slot = pending.popFirst() else { return }
                let parts = material.parts(forLectures: slot.lectureIDs)
                let subject = material.subjects[slot.lectureIDs.last ?? ""] ?? material.subjects[slot.lectureIDs.first ?? ""]
                let config = slot.kind == .practice ? practiceConfig : courseConfig
                group.addTask {
                    do {
                        guard let subject, let config else { throw CourseQuizError.nothingToQuiz }
                        let quiz = try await self.write(
                            slot: slot, courseID: courseID, courseTitle: material.courseTitle,
                            parts: parts, subject: subject, config: config,
                            learnerContext: learnerContext,
                            briefsDrawings: options.briefsDrawings
                        )
                        return (slot, .success(quiz))
                    } catch {
                        return (slot, .failure(error))
                    }
                }
            }
            for _ in 0..<Self.concurrentWrites { startNext() }
            for await (slot, outcome) in group {
                switch outcome {
                case .success(let quiz):
                    written.append(quiz)
                case .failure(let error):
                    failed.append(.init(slot: slot, message: error.localizedDescription))
                }
                done += 1
                await onProgress(done, wanted.count)
                startNext()
            }
        }
        let order = Dictionary(slots.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = CourseQuizGenerationResult(
            courseID: courseID,
            slots: slots,
            written: written.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) },
            kept: kept,
            failed: failed,
            lecturesWithoutMaterial: material.lecturesWithoutMaterial
        )
        result.covered = covered
        guard !Task.isCancelled else { return result }
        // A rewrite puts the course on the ladder: an old checkpoint goes once
        // the ladder's checkpoints written now ask about all its lectures.
        if options.rewrite {
            let rewritten = Set(written.filter { $0.kind == .checkpoint }.flatMap(\.lectureIDs))
            for quiz in offLadder where Set(quiz.lectureIDs).isSubset(of: rewritten) {
                do {
                    try await storage.deleteCourseQuiz(quiz.id)
                    result.retired.append(quiz)
                } catch {
                    courseQuizWriterLogger.error("Could not remove checkpoint \(quiz.id, privacy: .public) the ladder replaced: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        result.named = await nameUnnamedQuizzes(courseID: courseID, material: material, only: options.quizIDs)
        return result
    }

    /// Names the course's ForeverLM quizzes written before quizzes were
    /// named (no symbol yet): a topic title and a symbol from their
    /// questions, one small call each on the route that wrote them. A quiz
    /// the namer fails on keeps its name and is tried again next run.
    func nameUnnamedQuizzes(courseID: String, material: CourseQuizMaterial, only: Set<String>? = nil) async -> [CourseQuiz] {
        let stored: [CourseQuiz]
        do {
            stored = try await storage.loadCourseQuizzes(courseID: courseID)
        } catch {
            courseQuizWriterLogger.error("Reading the course's quizzes to name them failed: \(error.localizedDescription, privacy: .public)")
            stored = []
        }
        let unnamed = stored.filter { quiz in
            quiz.author == .foreverlm && quiz.symbol == nil && !quiz.questions.isEmpty
                && (only?.contains(quiz.id) ?? true)
        }
        guard !unnamed.isEmpty else { return [] }
        let practiceConfig = try? Self.config(for: .lectureQuizWriting)
        let courseConfig = try? Self.config(for: .courseQuizWriting)
        var named: [CourseQuiz] = []
        await withTaskGroup(of: CourseQuiz?.self) { group in
            var pending = unnamed[...]
            func startNext() {
                guard let quiz = pending.popFirst() else { return }
                let subject = material.subjects[quiz.lectureIDs.last ?? ""] ?? material.subjects[quiz.lectureIDs.first ?? ""]
                let config = quiz.kind == .practice ? practiceConfig : courseConfig
                group.addTask {
                    guard let subject, let config else { return nil }
                    do {
                        let name = try await AIUsageAttribution.withSource(AIUsageSource(source: subject)) {
                            try await self.aiService.nameCourseQuiz(
                                quiz, courseTitle: material.courseTitle, subject: subject, config: config
                            )
                        }
                        let symbol = Self.availableSymbol(name.symbol) ?? Self.fallbackSymbol(for: quiz.kind)
                        var renamed = quiz
                        if quiz.kind != .test, let title = CourseQuizNaming.cleanTitle(name.title) {
                            renamed.title = title
                        }
                        renamed.symbol = symbol
                        renamed.updatedAt = Date()
                        try await self.storage.saveCourseQuiz(renamed)
                        return renamed
                    } catch {
                        return nil
                    }
                }
            }
            for _ in 0..<Self.concurrentWrites { startNext() }
            for await renamed in group {
                if let renamed { named.append(renamed) }
                startNext()
            }
        }
        return named
    }

    /// The writer's symbol when this Mac has it; a made-up name draws nothing,
    /// so it never reaches the row.
    static func availableSymbol(_ raw: String?) -> String? {
        guard let symbol = CourseQuizNaming.cleanSymbol(raw),
              NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else { return nil }
        return symbol
    }

    /// The tile's glyph when the writer named no symbol this Mac has.
    static func fallbackSymbol(for kind: CourseQuiz.Kind) -> String {
        switch kind {
        case .practice: return "checklist"
        case .checkpoint: return "flag"
        case .test: return "flag.checkered"
        }
    }

    /// Writes and saves one quiz. The model's answer is checked against the
    /// material; a quiz with no question left fails rather than saving empty.
    ///
    /// Every point the material makes is asked about (product owner, 2026-09-27:
    /// "cover really all the points that are made"). A practice quiz is
    /// written in passes: its lecture first, then each of the lecture's
    /// readings in a call of its own, with the lecture's learning points, so
    /// a reading's questions add to the lecture's rather than repeat them. A
    /// checkpoint or the test reads its lectures and their readings in one
    /// call. After each call, a learning point it listed and left without a
    /// question gets one more call for exactly those points
    /// (`writeCovered`).
    func write(
        slot: CourseQuizSlot,
        courseID: String,
        courseTitle: String?,
        parts: [CourseQuizPart],
        subject: StudioArticle,
        config: AITaskConfig,
        learnerContext: String? = nil,
        briefsDrawings: Bool = false
    ) async throws -> CourseQuiz {
        guard !parts.isEmpty else { throw CourseQuizError.nothingToQuiz }
        // Each call may brief the quiz's whole allowance; the checks keep the
        // first ones in quiz order (`CourseQuizPictures.limitingDrawings`).
        let drawings = briefsDrawings ? CourseQuizPictures.maximumDrawingsPerQuiz : 0
        let draft: CourseQuizDraft
        let limit: Int
        if slot.kind == .practice {
            let lecture = Array(parts.filter { $0.reading == nil }.prefix(1))
            let readings = parts.filter { $0.reading != nil }
            let lectureDraft = try await writeCovered(
                kind: slot.kind, courseTitle: courseTitle, parts: lecture,
                questionCount: CourseQuizPlanning.questionCount(for: .practice, parts: lecture),
                subject: subject, config: config, learnerContext: learnerContext,
                drawings: drawings
            )
            let lecturePoints = lectureDraft.learningPoints ?? []
            // Each reading's pass, all at once. A failed pass fails the quiz:
            // a quiz that silently skipped a reading would read as covering it.
            let readingDrafts = try await withThrowingTaskGroup(of: (Int, CourseQuizDraft).self, returning: [Int: CourseQuizDraft].self) { group in
                for (offset, reading) in readings.enumerated() {
                    group.addTask {
                        let draft = try await self.writeCovered(
                            kind: slot.kind, courseTitle: courseTitle, parts: [reading],
                            questionCount: CourseQuizPlanning.readingQuestionCount(for: reading),
                            subject: subject, config: config, learnerContext: learnerContext,
                            lecturePoints: lecturePoints,
                            drawings: drawings
                        )
                        return (offset, draft)
                    }
                }
                var drafts: [Int: CourseQuizDraft] = [:]
                for try await (offset, draft) in group { drafts[offset] = draft }
                return drafts
            }
            // The reading's questions move to its part of the quiz, after
            // the lecture's.
            var questions = lectureDraft.questions
            for offset in readings.indices {
                let partNumber = lecture.count + offset + 1
                questions += (readingDrafts[offset]?.questions ?? [])
                    .prefix(CourseQuizPlanning.maximumQuestionsPerReading)
                    .map { $0.moved(toPart: partNumber) }
            }
            draft = CourseQuizDraft(
                questions: questions,
                learningPoints: lectureDraft.learningPoints,
                title: lectureDraft.title,
                symbol: lectureDraft.symbol
            )
            limit = CourseQuizPlanning.practiceQuestionLimit(readings: readings.count)
        } else {
            draft = try await writeCovered(
                kind: slot.kind, courseTitle: courseTitle, parts: parts,
                questionCount: CourseQuizPlanning.questionCount(for: slot.kind, parts: parts),
                subject: subject, config: config, learnerContext: learnerContext,
                drawings: drawings
            )
            limit = CourseQuizPlanning.maximumQuestionsPerQuiz
        }
        let previous = try await storage.loadCourseQuiz(slot.id)
        // A question the rewrite asks again keeps its id, and so its Memory
        // item, and the picture drawn or pinned for it.
        let questions = CourseQuizPlanning.questions(
            from: draft, parts: parts, limit: limit, previous: previous?.questions ?? [],
            drawingLimit: drawings
        )
        guard !questions.isEmpty else { throw CourseQuizError.noQuestions(slot.title) }
        let now = Date()
        // Named by what the questions cover, with a symbol for its tile. A
        // rewrite keeps the picture drawn for the quiz; Redraw replaces it.
        let quiz = CourseQuiz(
            id: slot.id,
            courseID: courseID,
            kind: slot.kind,
            title: CourseQuizNaming.title(for: slot, written: draft.title),
            lectureIDs: slot.lectureIDs,
            afterLectureID: slot.afterLectureID,
            questions: questions,
            author: .foreverlm,
            createdAt: previous?.createdAt ?? now,
            updatedAt: now,
            symbol: Self.availableSymbol(draft.symbol) ?? Self.fallbackSymbol(for: slot.kind),
            artwork: previous?.artwork
        )
        try await storage.saveCourseQuiz(quiz)
        return quiz
    }

    /// One writer call and, when its answer leaves learning points without a
    /// question, one more for exactly those (`CourseQuizCoverage`), whose
    /// questions join the first call's. A point still without a question
    /// after that is logged rather than asked for a third time: the second
    /// call already named it.
    func writeCovered(
        kind: CourseQuiz.Kind,
        courseTitle: String?,
        parts: [CourseQuizPart],
        questionCount: Int,
        subject: StudioArticle,
        config: AITaskConfig,
        learnerContext: String?,
        lecturePoints: [String]? = nil,
        drawings: Int = 0
    ) async throws -> CourseQuizDraft {
        let first = try await AIUsageAttribution.withSource(AIUsageSource(source: subject)) {
            try await aiService.writeCourseQuiz(
                kind: kind, courseTitle: courseTitle, parts: parts, questionCount: questionCount,
                subject: subject, config: config, learnerContext: learnerContext,
                lecturePoints: lecturePoints,
                drawings: drawings
            )
        }
        let missing = CourseQuizPlanning.uncoveredPoints(in: first, parts: parts)
        guard !missing.isEmpty, let points = first.learningPoints else { return first }
        let followUp = try await AIUsageAttribution.withSource(AIUsageSource(source: subject)) {
            try await aiService.writeCourseQuiz(
                kind: kind, courseTitle: courseTitle, parts: parts, questionCount: missing.count,
                subject: subject, config: config, learnerContext: learnerContext,
                lecturePoints: lecturePoints,
                coverage: CourseQuizCoverage(points: points, missing: missing),
                drawings: drawings
            )
        }
        let merged = CourseQuizDraft(
            questions: first.questions + followUp.questions,
            learningPoints: points,
            title: first.title,
            symbol: first.symbol
        )
        let stillMissing = CourseQuizPlanning.uncoveredPoints(in: merged, parts: parts)
        if !stillMissing.isEmpty {
            courseQuizWriterLogger.info("Quiz for \(subject.id, privacy: .public): \(stillMissing.count, privacy: .public) of \(points.count, privacy: .public) learning points still without a question after the coverage call")
        }
        return merged
    }

    // MARK: Pictures

    /// Draws a quiz's picture from its title and questions and keeps it in
    /// the quiz: square, `CourseQuizNaming.artworkPixelSize` on a side, a
    /// JPEG small enough to ride the Course record. Costs one image request,
    /// so it runs only when the learner asks: Draw Picture, or writing the
    /// quiz with `MacImageGenerationSettings.drawsForNewQuizzes` on.
    func drawArtwork(
        for quiz: CourseQuiz,
        courseTitle: String?,
        model: ImageGenerationModel,
        style: ImageGenerationCatalog.Style
    ) async throws -> CourseQuiz {
        let prompt = ImageGenerationCatalog.quizIconPrompt(
            topic: quiz.hasTopicTitle ? quiz.title : (courseTitle ?? quiz.title),
            courseTitle: courseTitle,
            keyIdeas: quiz.questions.prefix(4).map(\.question),
            style: style
        )
        let generated = try await ManagedImageGeneration.generate(
            prompt: prompt,
            model: model,
            shape: .square,
            quality: .low,
            usageTask: "course_quiz_icon",
            source: AIUsageSource(id: quiz.id, type: "course_quiz", title: quiz.title)
        )
        guard let artwork = Self.artworkJPEG(from: generated.data) else {
            throw ManagedImageGeneration.Failure.noImageReturned
        }
        var drawn = try await storage.loadCourseQuiz(quiz.id) ?? quiz
        drawn.artwork = artwork
        drawn.updatedAt = Date()
        try await storage.saveCourseQuiz(drawn)
        return drawn
    }

    /// Draws each quiz's picture, `concurrentWrites` at a time, calling
    /// `finished` as each one ends. Returns the message of each that failed,
    /// by quiz id; one failure never stops the others.
    @discardableResult
    func drawArtwork(
        for quizzes: [CourseQuiz],
        courseTitle: String?,
        model: ImageGenerationModel,
        style: ImageGenerationCatalog.Style,
        finished: @escaping @Sendable (_ quizID: String) async -> Void = { _ in }
    ) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            var failures: [String: String] = [:]
            var pending = quizzes[...]
            func startNext() {
                guard !Task.isCancelled, let quiz = pending.popFirst() else { return }
                group.addTask {
                    do {
                        _ = try await self.drawArtwork(for: quiz, courseTitle: courseTitle, model: model, style: style)
                        return (quiz.id, nil)
                    } catch {
                        return (quiz.id, error.localizedDescription)
                    }
                }
            }
            for _ in 0..<Self.concurrentWrites { startNext() }
            for await (quizID, error) in group {
                if let error { failures[quizID] = error }
                await finished(quizID)
                startNext()
            }
            return failures
        }
    }

    /// Square-crops and shrinks a drawn picture to the stored JPEG, lowering
    /// the quality until it fits `CourseQuizNaming.maximumArtworkBytes`.
    static func artworkJPEG(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let squared = MeetingIconService.squareThumbnail(image, pixels: CourseQuizNaming.artworkPixelSize) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: squared)
        for quality in [0.8, 0.65, 0.5, 0.35] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= CourseQuizNaming.maximumArtworkBytes {
                return jpeg
            }
        }
        return nil
    }

    func removeArtwork(quizID: String) async throws {
        guard var quiz = try await storage.loadCourseQuiz(quizID), quiz.artwork != nil else { return }
        quiz.artwork = nil
        quiz.updatedAt = Date()
        try await storage.saveCourseQuiz(quiz)
    }

    // MARK: Pictures for quizzes already written

    /// Gives the questions of quizzes already written the pictures that make
    /// their points clear (docs/lecture-quiz-design.md, "Pictures"): one
    /// picker call per quiz, on the quiz-writing route, choosing a lecture's
    /// slide or a reading's figure, and with `drawingModel` briefing a
    /// drawing where neither shows the point; then those briefs, and any
    /// left waiting from before, are drawn on that model. The questions
    /// themselves are left exactly as they were, ids and all. Capturing a
    /// lecture's slides is the caller's (it streams the video). A question
    /// with a picture keeps it unless `replacing`.
    func addQuestionPictures(
        courseID: String,
        quizIDs: Set<String>? = nil,
        replacing: Bool = false,
        drawingModel: ImageGenerationModel? = nil,
        onProgress: @escaping @Sendable (_ phase: CourseQuizPicturePhase, _ done: Int, _ total: Int) async -> Void = { _, _, _ in },
        onQuizDone: @escaping @Sendable (_ quizID: String) async -> Void = { _ in }
    ) async throws -> CourseQuizPictureResult {
        let material = try await material(courseID: courseID)
        let quizzes = try await storage.loadCourseQuizzes(courseID: courseID)
            .filter { quizIDs?.contains($0.id) ?? true }
        guard !quizzes.isEmpty else { return CourseQuizPictureResult(courseID: courseID, outcomes: []) }
        let drawing = drawingModel != nil
        let jobs = quizzes.map { quiz -> (quiz: CourseQuiz, parts: [CourseQuizPart], candidates: [Int]) in
            let parts = material.parts(forLectures: quiz.lectureIDs)
            return (quiz, parts, CourseQuizPictures.candidates(in: quiz, parts: parts, replacing: replacing, drawing: drawing))
        }
        let config = jobs.contains { !$0.candidates.isEmpty } ? try Self.config(for: .lectureQuizWriting) : nil
        var outcomes: [String: CourseQuizPictureResult.Outcome] = [:]
        await onProgress(.choosing, 0, jobs.count)
        await withTaskGroup(of: (String, CourseQuizPictureResult.Outcome).self) { group in
            var pending = jobs[...]
            var completed = 0
            func startNext() {
                guard !Task.isCancelled, let job = pending.popFirst() else { return }
                let subject = job.quiz.lectureIDs.lazy.compactMap { material.subjects[$0] }.first
                group.addTask {
                    guard !job.candidates.isEmpty else { return (job.quiz.id, .nothingToPicture) }
                    do {
                        guard let config, let subject else { throw CourseQuizError.nothingToQuiz }
                        // Drawings already briefed and waiting count against
                        // this quiz's allowance.
                        let waiting = job.quiz.questions.filter { $0.picture?.isAwaitingDrawing == true }.count
                        let drawings = drawing ? max(0, CourseQuizPictures.maximumDrawingsPerQuiz - waiting) : 0
                        let draft = try await AIUsageAttribution.withSource(AIUsageSource(source: subject)) {
                            try await self.aiService.pickCourseQuizPictures(
                                job.quiz,
                                parts: job.parts,
                                candidates: job.candidates,
                                courseTitle: material.courseTitle,
                                subject: subject,
                                config: config,
                                drawings: drawings
                            )
                        }
                        // Read again just before saving: a rename or a drawn
                        // picture that landed meanwhile is kept.
                        guard var current = try await self.storage.loadCourseQuiz(job.quiz.id),
                              current.questions.map(\.id) == job.quiz.questions.map(\.id) else {
                            return (job.quiz.id, .failed("the quiz changed while its pictures were chosen"))
                        }
                        let applied = CourseQuizPictures.applying(
                            draft, to: current, parts: job.parts, candidates: job.candidates, drawingLimit: drawings
                        )
                        guard applied.pinned > 0 else { return (job.quiz.id, .noneFitting) }
                        current.questions = applied.questions
                        current.updatedAt = Date()
                        try await self.storage.saveCourseQuiz(current)
                        return (job.quiz.id, .pictured(applied.pinned))
                    } catch {
                        courseQuizWriterLogger.error("Pictures for \(job.quiz.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                        return (job.quiz.id, .failed(error.localizedDescription))
                    }
                }
            }
            for _ in 0..<Self.concurrentWrites { startNext() }
            for await (quizID, outcome) in group {
                outcomes[quizID] = outcome
                completed += 1
                await onProgress(.choosing, completed, jobs.count)
                if drawingModel == nil { await onQuizDone(quizID) }
                startNext()
            }
        }
        var result = CourseQuizPictureResult(
            courseID: courseID,
            outcomes: jobs.map { ($0.quiz, outcomes[$0.quiz.id] ?? .failed(Task.isCancelled ? "stopped before it ran" : "not run")) }
        )
        if let drawingModel, !Task.isCancelled {
            result.drawing = await drawQuestionPictures(
                courseID: courseID,
                quizIDs: jobs.map { $0.quiz.id },
                courseTitle: material.courseTitle,
                model: drawingModel,
                onProgress: onProgress,
                onQuizDone: onQuizDone
            )
        }
        return result
    }

    // MARK: Drawing the pictures briefed for questions

    /// Draws the pictures briefed for these quizzes' questions — by a writer,
    /// the picture pass or an assistant's `brief` — up to
    /// `CourseQuizPictures.maximumDrawingsPerQuiz` a quiz, on `model`, and
    /// pins each to its question the moment it is drawn, so a run stopped
    /// halfway keeps what it drew. The picture is kept in the image store
    /// with its prompt as a compact JPEG
    /// (`compactDrawing`), and reaches the learner's other Macs and a team in
    /// the course's record (as `CourseQuizPicturePackage`), sent once when the
    /// run ends rather than again with every picture pinned
    /// (`CourseQuizPicturePackage.holdUploads`). Each is one image request,
    /// so this runs only when the learner asked: writing quizzes with drawing
    /// on, Add Pictures to Questions, or the MCP tools that say so. A quiz's
    /// first failure leaves its other briefs for the next run.
    func drawQuestionPictures(
        courseID: String,
        quizIDs: [String],
        courseTitle: String?,
        model: ImageGenerationModel,
        onProgress: @escaping @Sendable (_ phase: CourseQuizPicturePhase, _ done: Int, _ total: Int) async -> Void = { _, _, _ in },
        onQuizDone: @escaping @Sendable (_ quizID: String) async -> Void = { _ in }
    ) async -> CourseQuizDrawingResult {
        await onProgress(.drawing, 0, quizIDs.count)
        CourseQuizPicturePackage.holdUploads(courseID: courseID)
        var result = await drawQuestionPicturesHoldingUploads(
            quizIDs: quizIDs,
            courseTitle: courseTitle,
            model: model,
            onProgress: onProgress,
            onQuizDone: onQuizDone
        )
        CourseQuizPicturePackage.releaseUploads(courseID: courseID)
        // The course's record went out meanwhile without its pictures; one
        // more save sends them, once, with the package of the whole run. A
        // failure here is the run's too: the pictures were paid for and are
        // kept on this Mac, but no other device has them until a later save
        // of the course goes out.
        if result.drawnCount > 0, let quizID = result.drawn.keys.sorted().first {
            do {
                if let quiz = try await storage.loadCourseQuiz(quizID) {
                    try await storage.saveCourseQuiz(quiz)
                }
            } catch {
                courseQuizWriterLogger.error("Sending the pictures of course \(courseID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if result.failures[quizID] == nil {
                    result.failures[quizID] = "its pictures were drawn and kept on this Mac, but could not be sent to your other devices: \(error.localizedDescription)"
                }
            }
        }
        return result
    }

    private func drawQuestionPicturesHoldingUploads(
        quizIDs: [String],
        courseTitle: String?,
        model: ImageGenerationModel,
        onProgress: @escaping @Sendable (_ phase: CourseQuizPicturePhase, _ done: Int, _ total: Int) async -> Void,
        onQuizDone: @escaping @Sendable (_ quizID: String) async -> Void
    ) async -> CourseQuizDrawingResult {
        await withTaskGroup(of: (String, drawn: Int, waiting: Int, failure: String?).self) { group in
            var result = CourseQuizDrawingResult()
            var pending = quizIDs[...]
            var completed = 0
            func startNext() {
                guard !Task.isCancelled, let quizID = pending.popFirst() else { return }
                group.addTask {
                    let outcome = await self.drawQuestionPictures(quizID: quizID, courseTitle: courseTitle, model: model)
                    return (quizID, outcome.drawn, outcome.waiting, outcome.failure)
                }
            }
            for _ in 0..<Self.concurrentWrites { startNext() }
            for await entry in group {
                if entry.drawn > 0 { result.drawn[entry.0] = entry.drawn }
                if entry.waiting > 0 { result.waiting[entry.0] = entry.waiting }
                if let failure = entry.failure { result.failures[entry.0] = failure }
                completed += 1
                await onProgress(.drawing, completed, quizIDs.count)
                await onQuizDone(entry.0)
                startNext()
            }
            return result
        }
    }

    private func drawQuestionPictures(
        quizID: String,
        courseTitle: String?,
        model: ImageGenerationModel
    ) async -> (drawn: Int, waiting: Int, failure: String?) {
        let loaded: CourseQuiz?
        do {
            loaded = try await storage.loadCourseQuiz(quizID)
        } catch {
            courseQuizWriterLogger.error("Reading quiz \(quizID, privacy: .public) to draw its pictures failed: \(error.localizedDescription, privacy: .public)")
            return (0, 0, nil)
        }
        guard let quiz = loaded else { return (0, 0, nil) }
        let briefed = quiz.questions.filter { $0.picture?.isAwaitingDrawing == true }.count
        var drawn = 0
        for index in CourseQuizPictures.awaitingDrawing(in: quiz) {
            guard !Task.isCancelled else { break }
            let question = quiz.questions[index]
            guard let prompt = CourseQuizPictures.drawingPrompt(for: question, quizTitle: quiz.title, courseTitle: courseTitle),
                  let brief = question.picture?.brief else { continue }
            let title = "\(quiz.title): \(question.picture?.caption ?? GeneratedImageStore.altText(brief))"
            do {
                let generated = try await ManagedImageGeneration.generate(
                    prompt: prompt,
                    model: model,
                    shape: .landscape,
                    quality: .medium,
                    usageTask: "course_quiz_picture",
                    source: AIUsageSource(id: quiz.id, type: "course_quiz", title: quiz.title)
                )
                let modelName = model.name
                let modelID = model.id
                let stored = try await Task.detached(priority: .utility) {
                    try GeneratedImageStore.store(
                        Self.compactDrawing(generated),
                        origin: .drawn,
                        text: prompt,
                        title: title,
                        model: modelName,
                        modelID: modelID,
                        revising: nil
                    )
                }.value
                // Pinned only where the question still waits for this very
                // brief: a rewrite or an assistant's picture that landed
                // meanwhile wins, and the drawing stays in Images.
                guard var current = try await storage.loadCourseQuiz(quiz.id),
                      let at = current.questions.firstIndex(where: { $0.id == question.id }),
                      let waiting = current.questions[at].picture, waiting.isAwaitingDrawing, waiting.brief == brief else { continue }
                current.questions[at].picture = waiting.drawn(as: CourseQuizPicture.storedImageURL(id: stored.id))
                current.updatedAt = Date()
                try await storage.saveCourseQuiz(current)
                drawn += 1
            } catch {
                courseQuizWriterLogger.error("Drawing a picture for \(quiz.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return (drawn, briefed - drawn, error.localizedDescription)
            }
        }
        return (drawn, briefed - drawn, nil)
    }

    /// Longest side a question's drawing is kept at: wider than the chat
    /// column shows it, with room for a close look.
    static let drawingPixelSize = 1280

    /// A drawing as a quiz keeps it: a JPEG at most `drawingPixelSize` on its
    /// long side, on white. A picture on every question of a course is a few
    /// hundred drawings, and they travel in the course's record as one
    /// package, so each is a couple of hundred kilobytes rather than the
    /// megabyte or two of PNG the image model returns. The drawing as
    /// returned when it cannot be read, or would not get smaller.
    static func compactDrawing(_ image: GeneratedImage) -> GeneratedImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return image }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: drawingPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(
                  data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return image }
        // JPEG has no transparency: a transparent background would turn black.
        let bounds = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(thumbnail, in: bounds)
        guard let flattened = context.makeImage() else { return image }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return image }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length < image.data.count else { return image }
        return GeneratedImage(data: output as Data, mediaType: "image/jpeg")
    }

    static func config(for task: AITask) throws -> AITaskConfig {
        guard let config = KeychainService.resolveConfig(for: task) else {
            throw CourseQuizError.notConfigured(
                KeychainService.backgroundAIUnavailableMessage(for: task)
                    ?? "\(task.displayName) is not configured."
            )
        }
        return config
    }
}
#endif
