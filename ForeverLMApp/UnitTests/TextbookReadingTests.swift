import Foundation
import Testing
@testable import ForeverLM

/// Textbook readings in a course (docs/textbook-readings-design.md): the plan
/// checked against what was offered, the store's replace, the Course record's
/// units, the source-record merge that must not delete a reading, and the
/// pipeline with a canned planner. No test here writes a synced preference:
/// `LearnerProfile` writes reach the host's own account.
@Suite("Textbook Readings", .serialized)
struct TextbookReadingTests {

    // MARK: Fixtures

    private func draft(_ json: String) throws -> TextbookReadingDraft {
        try JSONDecoder().decode(TextbookReadingDraft.self, from: Data(json.utf8))
    }

    private let chapterEight = """
    # Chapter 8: Transporters
    [page 1]
    8
    TRANSPORTERS
    8.1 INTRODUCTION
    Mitochondria and bacteria continuously exchange metabolites.
    [page 2]
    222 BIOENERGETICS 4
    8.2 THE PRINCIPAL MITOCHONDRIAL TRANSPORT PROTEIN
    FAMILY
    The integration of metabolism between the matrix and cytoplasm requires traffic.
    [page 8]
    8.3 BACTERIAL TRANSPORT
    Bacteria have many transporters.
    """

    private func outline() -> TextbookOutline {
        TextbookOutline(
            bookID: "bio",
            title: "Bioenergetics",
            author: "Nicholls and Ferguson",
            edition: "4",
            chapters: [
                .init(
                    handle: "c3", number: 3, sourceID: "ch3", title: "Chapter 3: Quantitative Bioenergetics", pageCount: 26,
                    sections: TextbookOutline.sections(
                        chapterNumber: 3,
                        entries: [("3.1 Introduction", 0), ("3.2 Gibbs Energy", 3), ("3.3 Redox Potentials", 9), ("3.4 Ion Potentials", 16)],
                        pageCount: 26,
                        text: nil
                    ),
                    excerpt: "", progress: .read
                ),
                .init(
                    handle: "c8", number: 8, sourceID: "ch8", title: "Chapter 8: Transporters", pageCount: 34,
                    sections: TextbookOutline.sections(
                        chapterNumber: 8,
                        entries: [("8.1 Introduction", 0), ("8.2 The Principal Mitochondrial Transport Protein Family", 1), ("8.3 Bacterial Transport", 7)],
                        pageCount: 34,
                        text: chapterEight
                    ),
                    excerpt: "", progress: .unread
                ),
                .init(
                    handle: "c12", number: 12, sourceID: "ch12", title: "Chapter 12: Mitochondria in Pathology", pageCount: nil,
                    sections: [], excerpt: "Opening words", progress: .unread
                ),
            ]
        )
    }

    private func briefs(_ count: Int) -> [TextbookLectureBrief] {
        (1...count).map { TextbookLectureBrief(lectureID: "L\($0)", number: $0, title: "Lecture \($0)", material: "text", wasCut: false) }
    }

    // MARK: The book's outline

    @Test("Sections come from the chapter's own outline, in page order, each to the page the next opens on")
    func sectionsFromOutline() {
        let sections = TextbookOutline.sections(
            chapterNumber: 8,
            entries: [("8.2 The Principal Mitochondrial Transport Protein Family", 1), ("8.1 Introduction", 0), ("8.3 Bacterial Transport", 7), ("Off the end", 40), ("  ", 3)],
            pageCount: 34,
            text: chapterEight
        )
        #expect(sections.map(\.handle) == ["c8s1", "c8s2", "c8s3"])
        #expect(sections.map(\.pages) == [1...2, 2...8, 8...34])
        #expect(sections[1].excerpt.hasPrefix("The integration of metabolism"))
        #expect(TextbookOutline.sections(chapterNumber: 1, entries: [("Only", 0)], pageCount: 5, text: nil).isEmpty)
        #expect(TextbookOutline.sections(chapterNumber: 1, entries: [("A", 0), ("B", 2)], pageCount: 0, text: nil).isEmpty)
    }

    @Test("Page markers split a chapter's text, and count its pages when the file is not at hand")
    func pageMarkers() {
        let pages = TextbookOutline.pageTexts(chapterEight)
        #expect(pages.keys.sorted() == [1, 2, 8])
        #expect(pages[1]?.contains("# Chapter 8") == false)
        #expect(TextbookOutline.pageCount(ofText: chapterEight) == 3)
        #expect(TextbookOutline.pageCount(ofText: "An EPUB chapter has no pages.") == nil)
        #expect(TextbookOutline.chapterExcerpt("An EPUB chapter has no pages.") == "An EPUB chapter has no pages.")
    }

    // MARK: The plan, checked

    @Test("Code decides the readings: unknown lectures and handles go, chapters split, runs merge, gaps split")
    func placementsAreChecked() throws {
        let plan = try draft("""
        {"summary": "Thermodynamics first.", "lectures": [
          {"lecture": 3, "readings": [{"parts": ["c8s2", "c3s2", "c3s3", "nonsense"], "why": "  Carriers   and\\n Gibbs energy. "}]},
          {"lecture": "1", "readings": [{"parts": "C3S1", "why": "Background."}, {"parts": ["c3s1", "c3s4"], "why": "Gap."}]},
          {"lecture": 9, "readings": [{"parts": ["c8s1"], "why": "No such lecture."}]},
          {"lecture": 4, "readings": []}
        ]}
        """)
        let placed = TextbookReadingPlanning.placements(from: plan, outline: outline(), lectures: briefs(5))
        #expect(placed.map(\.lectureNumber) == [1, 1, 3, 3])

        let first = placed.filter { $0.lectureNumber == 1 }
        #expect(first.map(\.pages) == [1...4, 17...26])
        #expect(first.map(\.title) == ["3.1 Introduction", "3.4 Ion Potentials"])

        let third = placed.filter { $0.lectureNumber == 3 }
        #expect(third.map(\.chapterSourceID) == ["ch8", "ch3"])
        #expect(third[1].pages == 4...17)
        #expect(third[1].title == "3.2 Gibbs Energy · 3.3 Redox Potentials")
        #expect(third[0].reason == "Carriers and Gibbs energy.")
    }

    @Test("A chapter handle, or a chapter without sections, reads the whole chapter; no reason is invented")
    func wholeChapters() throws {
        let plan = try draft("""
        {"lectures": [{"lecture": 2, "readings": [{"parts": ["c12"]}, {"parts": ["c8"], "why": "All of it."}]}]}
        """)
        let placed = TextbookReadingPlanning.placements(from: plan, outline: outline(), lectures: briefs(2))
        #expect(placed.count == 2)
        #expect(placed[0].chapterSourceID == "ch12" && placed[0].pages == nil && placed[0].reason.isEmpty)
        #expect(placed[1].chapterSourceID == "ch8" && placed[1].pages == nil)
        #expect(TextbookReading.unit(for: placed[0]) == nil)
        #expect(TextbookReading.item(for: placed[0], sortIndex: 0, createdAt: Date()).label == nil)
    }

    @Test("A lecture keeps at most three readings, never the same pages twice")
    func capAndDedupe() throws {
        let plan = try draft("""
        {"lectures": [{"lecture": 1, "readings": [
          {"parts": ["c3s1"], "why": "a"}, {"parts": ["c3s1"], "why": "again"}, {"parts": ["c3s2"], "why": "b"},
          {"parts": ["c3s3"], "why": "c"}, {"parts": ["c3s4"], "why": "d"}
        ]}]}
        """)
        let placed = TextbookReadingPlanning.placements(from: plan, outline: outline(), lectures: briefs(1))
        #expect(placed.map(\.reason) == ["a", "b", "c"])
    }

    @Test("A draft without lectures is not a plan")
    func draftNeedsLectures() {
        #expect(throws: (any Error).self) {
            _ = try draft(#"{"summary": "nothing"}"#)
        }
    }

    // MARK: Lecture material

    @Test("Lecture budgets keep a short lecture whole and share the rest by length")
    func lectureBudgets() {
        #expect(TextbookReadingPlanning.lectureBudgets(lengths: ["a": 1_000, "b": 2_000, "c": 0]) == ["a": 1_000, "b": 2_000])
        let budgets = TextbookReadingPlanning.lectureBudgets(lengths: ["a": 200_000, "b": 10_000, "c": 1_000])
        #expect(budgets["c"] == 1_000)
        #expect((budgets["b"] ?? 0) >= TextbookReadingPlanning.minimumLectureCharacters)
        #expect((budgets["a"] ?? 0) <= 200_000)
    }

    @Test("A long transcript is sampled through the lecture, after its section headings")
    func lectureMaterial() {
        let transcript = "## General Properties\n[0:00] hi\n## Ionophores\n[1:00] valinomycin " + String(repeating: "x", count: 10_000)
        let material = TextbookReadingPlanning.lectureMaterial(transcript, budget: 1_000)
        #expect(material.hasPrefix("Sections: General Properties; Ionophores"))
        #expect(material.components(separatedBy: "[…]").count == 4)
        #expect(material.count < 1_200)
        #expect(TextbookReadingPlanning.lectureMaterial("short", budget: 100) == "short")
        #expect(TextbookReadingPlanning.lectureMaterial("anything", budget: 0).isEmpty)
    }

    // MARK: Identity and storage shape

    @Test("Units and reading items are named by what they are")
    func identities() {
        #expect(TextbookReading.locator(3...9) == "3-9")
        #expect(TextbookReading.pages(fromLocator: "3-9") == 3...9)
        #expect(TextbookReading.pages(fromLocator: "9-3") == nil)
        #expect(TextbookReading.pages(fromLocator: "0-2") == nil)
        let unit = TextbookReading.unitID(sourceID: "ch8", pages: 2...8)
        #expect(unit == TextbookReading.unitID(sourceID: "ch8", pages: 2...8))
        #expect(unit != TextbookReading.unitID(sourceID: "ch8", pages: 2...9))
        #expect(unit.hasPrefix("su-"))
        #expect(TextbookReading.itemID(lectureID: "L1", sourceID: "ch8", pages: nil)
            != TextbookReading.itemID(lectureID: "L2", sourceID: "ch8", pages: nil))
    }

    // MARK: The learner

    @Test("The learner block carries their words, their focus and the Notebooks the course serves")
    func learnerBlock() {
        #expect(CourseLearnerContext().promptBlock == nil)
        let context = CourseLearnerContext(
            aboutYou: "  Physicist.\nNew to biology. ",
            focus: "Membrane potential measurements",
            notebooks: [.init(title: "Mito Phenotyping", instructions: String(repeating: "i", count: 2_000), researchQuestions: ["Which layer?"], goals: ["Pitch (by 2026-10-01)"])]
        )
        let block = context.promptBlock ?? ""
        #expect(block.contains("Where they are coming from, in their words: Physicist. New to biology."))
        #expect(block.contains("What they need from this course, in their words: Membrane potential measurements"))
        #expect(block.contains("\"Mito Phenotyping\""))
        #expect(!block.contains(String(repeating: "i", count: CourseLearnerContext.maximumInstructionCharacters + 1)))
        #expect(!context.isEmpty)
        #expect(!CourseLearnerContext(focus: "only a focus").isEmpty)
    }

    @Test("About you is a synced row, a course's focus an Enrollment; overlong words are refused without a write")
    func profileRefusals() {
        #expect(SyncedPreferenceKeys.isSynced(LearnerProfile.aboutYouPreferenceKey))
        // A course's focus is the member's Enrollment record (§3.5.12), no preference row.
        let focusKey = LearnerProfile.courseFocusPreferenceKey(courseID: "course")
        #expect(!SyncedPreferenceKeys.isSynced(focusKey, for: .two))
        let before = LearnerProfile.aboutYou
        #expect(!LearnerProfile.setAboutYou(String(repeating: "a", count: LearnerProfile.maximumAboutYouLength + 1)))
        #expect(LearnerProfile.aboutYou == before)
        #expect(!LearnerProfile.setCourseFocus(String(repeating: "a", count: LearnerProfile.maximumFocusLength + 1), courseID: "course"))
    }

    // MARK: The store

    /// A two-lecture course with a video on each, and three chapters of a book.
    private func seed(_ store: KnowledgeStore) throws -> [CourseSession] {
        try store.saveCourseGroup(name: "course", metadata: CourseMetadata(title: "Mitochondrial Bioenergetics"))
        let lectures = [
            CourseSession(courseName: "course", number: 1, title: "Ion transport"),
            CourseSession(courseName: "course", number: 2, title: "Respirometry"),
        ]
        for (index, lecture) in lectures.enumerated() {
            try store.saveCourseLecture(lecture)
            var video = StudioArticle(
                url: "https://www.youtube.com/watch?v=abcdefghij\(index)", title: lecture.title,
                sourceType: .video, discoveryOrigin: .manual, id: "video-\(index + 1)"
            )
            video.content = "[0:00] Lecture \(index + 1)."
            video.state = .ready
            try store.saveSource(video)
            _ = try store.saveCourseLectureItem(CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0))
        }
        for (id, title) in [("ch3", "Chapter 3"), ("ch8", "Chapter 8"), ("ch12", "Chapter 12")] {
            try seedChapter(store, id: id, title: title, book: "bio")
        }
        try seedChapter(store, id: "other-ch1", title: "Other Chapter 1", book: "other")
        return lectures
    }

    private func seedChapter(_ store: KnowledgeStore, id: String, title: String, book: String) throws {
        let file = "Books/\(book)/Chapters/\(id).pdf"
        var chapter = StudioArticle(
            url: file, title: title, sourceType: .book, discoveryOrigin: .manual,
            parentGroup: book, localFilePath: file, id: id
        )
        chapter.content = "[page 1]\n\(title) text."
        chapter.state = .ready
        try store.saveSource(chapter)
    }

    private func placement(_ lecture: CourseSession, _ chapter: String, _ pages: ClosedRange<Int>?, reason: String = "Because.") -> TextbookReadingPlacement {
        TextbookReadingPlacement(
            lectureID: lecture.id, lectureNumber: lecture.number, chapterSourceID: chapter, chapterNumber: 8,
            chapterTitle: "Chapter", pages: pages, title: pages == nil ? "Chapter" : "8.2 Transporters", reason: reason
        )
    }

    @Test("Readings follow each lecture's own items, name their pages, and a second plan of the book replaces the first")
    func replaceReadings() throws {
        let store = try KnowledgeStore(inMemory: true)
        let lectures = try seed(store)
        let book: Set<String> = ["ch3", "ch8", "ch12"]
        try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: ["other-ch1"], placements: [placement(lectures[1], "other-ch1", nil)])

        let written = try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: book, placements: [
            placement(lectures[0], "ch8", 2...8, reason: "Carriers."),
            placement(lectures[0], "ch12", nil),
            placement(lectures[1], "ch8", 2...8),
        ])
        #expect(written.map(\.sortIndex) == [1, 2, 2])
        #expect(written[0].label == "Carriers.")
        #expect(written[0].role == .reading)
        let units = try store.loadCourseSourceUnits()
        #expect(units.count == 1, "the same pages are one unit however many lectures read them")
        let unit = try #require(units[written[0].sourceUnitId ?? ""])
        #expect(unit.locator == "2-8" && unit.kind == TextbookReading.unitKind && unit.sourceId == "ch8")
        #expect(written[1].sourceUnitId == nil)

        // Planning the book again replaces its readings, and only its readings.
        try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: book, placements: [
            placement(lectures[0], "ch3", 4...9),
        ])
        let items = try store.loadCourseLectureItems()
        let readings = items.filter { $0.role == .reading }
        #expect(Set(readings.compactMap(\.sourceId)) == ["ch3", "other-ch1"])
        #expect(items.filter { $0.role == .video }.count == 2)
        let remaining = try store.loadCourseSourceUnits()
        #expect(remaining.values.map(\.sourceId) == ["ch3"])
        #expect(try store.loadSourceUnits(ids: [unit.id]).isEmpty, "pages no reading names any more are gone")
    }

    @Test("A reading must be in the course and in the book")
    func replaceRefusals() throws {
        let store = try KnowledgeStore(inMemory: true)
        let lectures = try seed(store)
        #expect(throws: (any Error).self) {
            try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: ["ch8"], placements: [placement(lectures[0], "ch3", 1...2)])
        }
        let stranger = CourseSession(courseName: "elsewhere", number: 1)
        #expect(throws: (any Error).self) {
            try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: ["ch8"], placements: [placement(stranger, "ch8", 1...2)])
        }
        #expect(try store.loadCourseLectureItems().filter { $0.role == .reading }.isEmpty)
    }

    @Test("A book's chapters come in reading order, and unavailable ones only when asked for")
    func bookChapters() throws {
        let store = try KnowledgeStore(inMemory: true)
        _ = try seed(store)
        #expect(try store.bookChapterSourceIDs(bookID: "bio").map(\.sourceID) == ["ch3", "ch8", "ch12"])
        try store.writeSourceHidden("ch12", hidden: true, hiddenAt: Date())
        #expect(try store.bookChapterSourceIDs(bookID: "bio").map(\.sourceID) == ["ch3", "ch8"])
        #expect(try store.bookChapterSourceIDs(bookID: "bio", includingUnavailable: true).count == 3)
        #expect(try store.bookGroupIDs().isSuperset(of: ["bio", "other"]))
        #expect(try store.bookGroupID(ofChapter: "ch8") == "bio")
        #expect(try store.bookGroupID(ofChapter: "video-1") == nil)
    }

    @Test("The Course record carries its readings' units, and another Mac applies them before the items")
    func courseRecordCarriesUnits() throws {
        let store = try KnowledgeStore(inMemory: true)
        let lectures = try seed(store)
        try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: ["ch3", "ch8", "ch12"], placements: [
            placement(lectures[0], "ch8", 2...8),
        ])
        let payload = try #require(try store.loadCourseForSync("course"))
        let decoded = try JSONDecoder().decode(CloudKitCoursePayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.sourceUnits?.map(\.locator) == ["2-8"])

        // Another Mac with the same library but no units yet.
        let other = try KnowledgeStore(inMemory: true)
        _ = try seed(other)
        try other.withoutSyncTracking {
            if let units = decoded.sourceUnits { try other.upsertSourceUnitsFromSync(units) }
            try other.saveCourseOutline(courseName: "course", lectures: decoded.lectures, items: decoded.lectureItems)
        }
        let reading = try #require(try other.loadCourseLectureItems().first { $0.role == .reading })
        #expect(try other.loadCourseSourceUnits()[reading.sourceUnitId ?? ""]?.locator == "2-8")
    }

    @Test("A Course record from a build without units decodes with none")
    func olderCoursePayload() throws {
        let json = #"{"id": "course", "name": "Course", "title": "Course", "isHidden": false, "lectures": [], "lectureItems": []}"#
        let payload = try JSONDecoder().decode(CloudKitCoursePayload.self, from: Data(json.utf8))
        #expect(payload.sourceUnits == nil)
    }

    @Test("A chapter's record from a Mac that has not heard of a unit keeps the reading that uses it")
    func sourceRecordMergesUnits() throws {
        let store = try KnowledgeStore(inMemory: true)
        let lectures = try seed(store)
        let written = try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: ["ch3", "ch8", "ch12"], placements: [
            placement(lectures[0], "ch8", 2...8),
        ])
        let unused = SourceUnit(id: "stale-unit", sourceId: "ch8", kind: TextbookReading.unitKind, locator: "20-21")
        try store.upsertSourceUnitsFromSync([unused])

        try store.withoutSyncTracking {
            try store.saveSourceUnitsRecord(sourceID: "ch8", units: [])
        }
        let items = try store.loadCourseLectureItems()
        #expect(items.contains { $0.id == written[0].id }, "the reading survives")
        let units = try store.loadSourceUnits(ids: [written[0].sourceUnitId ?? "", "stale-unit"])
        #expect(units.map(\.id) == [written[0].sourceUnitId ?? ""], "a referenced unit stays; an unused one the record lacks goes")

        // The same unit arriving again is an update, never a delete and re-insert.
        let same = try #require(units.first)
        try store.withoutSyncTracking {
            try store.saveSourceUnitsRecord(sourceID: "ch8", units: [same])
        }
        #expect(try store.loadCourseLectureItems().contains { $0.id == written[0].id })
    }

    // MARK: The pipeline

    private actor Seen {
        var request: TextbookReadingRequest?
        func record(_ request: TextbookReadingRequest) { self.request = request }
    }

    private func makeTemporaryStorage() -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextbookReadingTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StorageService(storeRoot: root), root)
    }

    private func seedStorage(_ storage: StorageService) async throws -> [CourseSession] {
        try await storage.saveCourseGroup(name: "course", metadata: CourseMetadata(title: "Mitochondrial Bioenergetics"))
        var lectures: [CourseSession] = []
        for number in 1...2 {
            let lecture = CourseSession(courseName: "course", number: number, title: number == 1 ? "Ion transport" : "Respirometry")
            try await storage.saveCourseLecture(lecture)
            var video = StudioArticle(
                url: "https://www.youtube.com/watch?v=klmnopqrst\(number)", title: lecture.title ?? "",
                sourceType: .video, discoveryOrigin: .manual, id: "video-\(number)"
            )
            video.content = "## Carriers\n[0:00] The adenine nucleotide translocator exchanges ATP for ADP.\n## Uniporter\n[1:00] Calcium enters through the uniporter."
            video.state = .ready
            try await storage.saveSource(video)
            _ = try await storage.saveCourseLectureItem(CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0))
            lectures.append(lecture)
        }
        for id in ["ch3", "ch8", "ch12"] {
            let file = "Books/bio/Chapters/\(id).pdf"
            var chapter = StudioArticle(url: file, title: id, sourceType: .book, discoveryOrigin: .manual, parentGroup: "bio", localFilePath: file, id: id)
            chapter.content = "[page 1]\n\(id)"
            chapter.state = .ready
            try await storage.saveSource(chapter)
        }
        return lectures
    }

    @Test("The pipeline shows the planner the learner, the book and the lectures, then saves the checked plan")
    func pipeline() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let lectures = try await seedStorage(storage)
        let seen = Seen()
        let book = outline()
        let service = TextbookReadingService(
            storage: storage,
            readOutline: { _ in book },
            plan: { request in
                await seen.record(request)
                return try JSONDecoder().decode(TextbookReadingDraft.self, from: Data("""
                {"summary": "You know the physics; the carriers are new.", "lectures": [
                  {"lecture": 1, "readings": [{"parts": ["c8s2"], "why": "The carrier family the lecture assumes."}]},
                  {"lecture": 2, "readings": []}
                ]}
                """.utf8))
            }
        )
        let context = CourseLearnerContext(aboutYou: "A physicist new to biology.", focus: "Measuring membrane potential")
        let result = try await service.run(courseID: "course", bookID: "bio", context: context)

        let request = try #require(await seen.request)
        #expect(request.courseTitle == "Mitochondrial Bioenergetics")
        #expect(request.lectures.map(\.title) == ["Ion transport", "Respirometry"])
        #expect(request.context.aboutYou == "A physicist new to biology.")
        if !StudioSidebarTab.excludedKnowledgeTabs().contains(.videos) {
            #expect(request.lectures[0].material.contains("adenine nucleotide translocator"))
        }
        let message = AIService.textbookReadingUserMessage(request)
        #expect(message.contains("Where they are coming from, in their words: A physicist new to biology."))
        #expect(message.contains("c8s2 8.2 The Principal Mitochondrial Transport Protein Family"))
        #expect(message.contains("=== Lecture 1: Ion transport ==="))

        #expect(result.summary == "You know the physics; the carriers are new.")
        #expect(result.placements.count == 1)
        let items = try await storage.loadCourseLectureItems().filter { $0.role == .reading }
        #expect(items.count == 1)
        #expect(items.first?.lectureId == lectures[0].id)
        #expect(items.first?.sourceId == "ch8")
        #expect(items.first?.label == "The carrier family the lecture assumes.")

        _ = try await service.run(courseID: "course", bookID: "bio", context: CourseLearnerContext())
        let courseOnlyRequest = try #require(await seen.request)
        #expect(courseOnlyRequest.context.isEmpty)
        let courseOnlyMessage = AIService.textbookReadingUserMessage(courseOnlyRequest)
        #expect(courseOnlyMessage.hasPrefix("Textbook: Bioenergetics"))
        #expect(courseOnlyMessage.contains("Course: Mitochondrial Bioenergetics"))
        #expect(!courseOnlyMessage.contains("The learner:"))
    }

    @Test("An empty learner context still plans from the course, while an empty plan preserves earlier readings")
    func pipelineRefusals() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let lectures = try await seedStorage(storage)
        let book = outline()
        try await storage.replaceTextbookReadings(courseID: "course", bookID: "bio", placements: [
            placement(lectures[0], "ch3", 1...4),
        ])
        let empty = TextbookReadingService(
            storage: storage,
            readOutline: { _ in book },
            plan: { _ in try JSONDecoder().decode(TextbookReadingDraft.self, from: Data(#"{"lectures": [{"lecture": 1, "readings": [{"parts": ["c99"]}]}]}"#.utf8)) }
        )
        await #expect(throws: TextbookReadingError.nothingToRead(book: "Bioenergetics")) {
            _ = try await empty.run(courseID: "course", bookID: "bio", context: CourseLearnerContext())
        }
        let readings = try await storage.loadCourseLectureItems().filter { $0.role == .reading }
        #expect(readings.map(\.sourceId) == ["ch3"], "the earlier plan stays when a new one places nothing")
    }

    // MARK: MCP

    @Test("The tool is a writer that spends and replaces, and holds no store gate while it plans")
    func toolRegistration() {
        #expect(MCPToolRegistry().tools.contains { $0.name == "add_textbook_to_course" })
        #expect(MCPToolRegistry().tools.contains { $0.name == "save_course_textbook_readings" })
        // Until 2026-09-27 it shared the gate for the whole minute, which still
        // held up the first writer to arrive and every call queued behind it.
        #expect(MCPToolRegistry.selfGatedToolNames.contains("add_textbook_to_course"))
        #expect(MCPToolRegistry.selfGatedToolNames.contains("save_course_textbook_readings"))
        #expect(!MCPToolRegistry.sharedGateWritingToolNames.contains("add_textbook_to_course"))
        let annotations = MCPToolRegistry.annotations(for: "add_textbook_to_course")
        #expect(annotations["readOnlyHint"] as? Bool == false)
        #expect(annotations["destructiveHint"] as? Bool == true)
        #expect(annotations["openWorldHint"] as? Bool == true)
        let authored = MCPToolRegistry.annotations(for: "save_course_textbook_readings")
        #expect(authored["readOnlyHint"] as? Bool == false)
        #expect(authored["destructiveHint"] as? Bool == true)
        #expect(authored["openWorldHint"] as? Bool == false)
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("save_course_textbook_readings"))
    }

    @Test("An assistant can author exact textbook readings without a planning call")
    func authoredReadings() throws {
        let lectures = [
            CourseSession(id: "L1", courseName: "course", number: 1, title: "Foundations"),
            CourseSession(id: "L2", courseName: "course", number: 2, title: "Transport"),
        ]
        let rows: [Any] = [
            [
                "lecture_id": "L2", "chapter_source_id": "ch8",
                "first_page": 2, "last_page": 8,
                "title": "8.2 Transport proteins", "reason": "Connect the carrier mechanism to the lecture.",
            ] as [String: Any],
            [
                "lecture_id": "L1", "chapter_source_id": "ch12",
            ] as [String: Any],
        ]
        let placements = try MCPDataStore.authoredTextbookReadingPlacements(
            rows,
            outline: outline(),
            lectures: lectures
        )
        #expect(placements.map(\.lectureID) == ["L1", "L2"], "course order wins over payload order")
        #expect(placements[0].pages == nil && placements[0].title == "Chapter 12: Mitochondria in Pathology")
        #expect(placements[1].pages == 2...8)
        #expect(placements[1].title == "8.2 Transport proteins")
        #expect(placements[1].reason == "Connect the carrier mechanism to the lecture.")
    }

    @Test("Authored textbook readings reject unaddressable pages and foreign identities")
    func authoredReadingRefusals() {
        let lectures = [CourseSession(id: "L1", courseName: "course", number: 1)]
        let book = outline()
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.authoredTextbookReadingPlacements([
                ["lecture_id": "L1", "chapter_source_id": "ch8", "first_page": 2, "last_page": 35, "title": "Too far"] as [String: Any],
            ], outline: book, lectures: lectures)
        }
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.authoredTextbookReadingPlacements([
                ["lecture_id": "elsewhere", "chapter_source_id": "ch8"] as [String: Any],
            ], outline: book, lectures: lectures)
        }
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.authoredTextbookReadingPlacements([
                ["lecture_id": "L1", "chapter_source_id": "another-book"] as [String: Any],
            ], outline: book, lectures: lectures)
        }
        #expect(throws: MCPError.self) {
            _ = try MCPDataStore.authoredTextbookReadingPlacements([
                ["lecture_id": "L1", "chapter_source_id": "ch8", "first_page": 2, "title": "Half a range"] as [String: Any],
            ], outline: book, lectures: lectures)
        }
    }

    @Test("A book is found by id, by a chapter's source id, or by a title only it has")
    func resolveBook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textbook_mcp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mcp = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let store = try mcp.knowledgeStore()
        _ = try seed(store)
        try store.saveBookMetadata(groupName: "bio", title: "Bioenergetics", coverPath: nil)
        try store.saveBookMetadata(groupName: "other", title: "Bioenergetics Workbook", coverPath: nil)

        #expect(try mcp.resolveTextbookID("bio", store: store) == "bio")
        #expect(try mcp.resolveTextbookID("ch8", store: store) == "bio")
        #expect(try mcp.resolveTextbookID("  bioenergetics ", store: store) == "bio")
        #expect(try mcp.resolveTextbookID("workbook", store: store) == "other")
        #expect(throws: MCPError.self) { _ = try mcp.resolveTextbookID("energetics", store: store) }
        #expect(throws: MCPError.self) { _ = try mcp.resolveTextbookID("Molecular Biology", store: store) }
    }

    @Test("get_course lists a reading with its pages, chapter, ids and reason")
    func getCourseShowsReadings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textbook_mcp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mcp = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let store = try mcp.knowledgeStore()
        let lectures = try seed(store)
        let written = try store.replaceTextbookReadings(courseID: "course", bookChapterIDs: ["ch3", "ch8", "ch12"], placements: [
            placement(lectures[0], "ch8", 2...8, reason: "The carriers."),
        ])
        let text = try mcp.getCourse(courseIdentifier: "course")
        #expect(text.contains("- Reading: 8.2 Transporters — Chapter 8, pages 2–8 of the chapter (item_id: \(written[0].id), role: reading, source_id: ch8). Why: The carriers."))
    }
}
