import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

@Suite("MCP course tools")
struct MCPCourseToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_course_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, directory.path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("course tools are registered and MCP instructions require lookup first")
    func courseWorkflowIsDiscoverable() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("list_courses"))
        #expect(toolNames.contains("get_course"))
        #expect(toolNames.contains("get_lecture_papers"))
        #expect(toolNames.contains("create_course"))
        #expect(toolNames.contains("update_course"))
        #expect(toolNames.contains("delete_course"))
        #expect(toolNames.contains("add_paper_to_lecture"))
        #expect(toolNames.contains("find_lecture_papers"))
        #expect(toolNames.contains("ingest_lecture_papers"))
        #expect(MCPToolRegistry.annotations(for: "find_lecture_papers")["openWorldHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "get_lecture_papers")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "ingest_lecture_papers")["openWorldHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "update_course")["destructiveHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "delete_course")["destructiveHint"] as? Bool == true)
        #expect(Prompts.mcpServerInstructions.contains("Before creating a course"))
        #expect(Prompts.mcpServerInstructions.contains("stable course_id"))
        #expect(Prompts.mcpServerInstructions.contains("add_paper_to_lecture"))
        #expect(Prompts.mcpServerInstructions.contains("get_lecture_papers"))
        #expect(Prompts.mcpServerInstructions.contains("find_lecture_papers"))
        #expect(Prompts.mcpServerInstructions.contains("ingest_lecture_papers"))
        #expect(Prompts.mcpServerInstructions.contains("Use update_course with the stable course_id"))
        #expect(Prompts.mcpServerInstructions.contains("Use delete_course only after confirming"))
        #expect(Prompts.mcpServerInstructions.contains("write quiz content here and use save_course_quiz"))
        #expect(Prompts.mcpServerInstructions.contains("make an image here and use save_image"))
        #expect(Prompts.mcpServerInstructions.contains("$3 default ceiling"))
        #expect(AITask.lecturePaperDiscovery.sourceType == .course)
        #expect(AITask.advancedTasks.contains(.lecturePaperDiscovery))
        #expect(AITask.lecturePaperDiscovery.defaultPrompt == Prompts.lecturePaperDiscovery)
    }

    @Test("listCourses exposes stable IDs and getCourse exposes lecture item IDs")
    func listAndInspectCourse() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let courseID = "stanford-cs336"

        try knowledgeStore.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(
                courseCode: "CS336",
                title: "Language Modeling from Scratch",
                institution: "Stanford",
                instructors: "Tatsunori Hashimoto"
            )
        )
        let lecture = CourseSession(
            id: "lecture-1",
            courseName: courseID,
            number: 1,
            title: "Assignment 1: Basics"
        )
        try knowledgeStore.saveCourseLecture(lecture)

        var source = StudioArticle(
            url: "https://example.com/assignment-1",
            title: "CS336 Assignment 1",
            sourceType: .course,
            id: "assignment-1"
        )
        source.parentGroup = courseID
        source.content = "Assignment text"
        source.wordCount = 2
        source.state = .ready
        try knowledgeStore.saveSource(source)

        let item = CourseLectureItem(
            id: "lecture-item-1",
            lectureId: lecture.id,
            sourceId: source.id,
            role: .exercise
        )
        try knowledgeStore.saveCourseLectureItem(item)

        let courses = try store.listCourses()
        #expect(courses.contains("Language Modeling from Scratch"))
        #expect(courses.contains("id: \(courseID)"))
        #expect(courses.contains("course_code: CS336"))
        #expect(courses.contains("institution: Stanford"))
        #expect(courses.contains("lectures: 1"))
        #expect(courses.contains("grouped_sources: 1"))
        #expect(courses.contains("lecture_items: 1"))

        let course = try store.getCourse(courseIdentifier: courseID)
        #expect(course.contains("course_id: \(courseID)"))
        #expect(course.contains("lecture_id: \(lecture.id)"))
        #expect(course.contains("item_id: \(item.id)"))
        #expect(course.contains("source_id: \(source.id)"))
        #expect(course.contains("role: exercise"))
    }

    @Test("papers can be associated with a lecture and retrieved with metadata")
    func associateAndGetLecturePapers() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let courseID = "course-ml"
        let lecture = CourseSession(
            id: "lecture-attention",
            courseName: courseID,
            number: 4,
            title: "Attention"
        )

        try knowledgeStore.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(title: "Machine Learning")
        )
        try knowledgeStore.saveCourseLecture(lecture)

        var paper = StudioArticle(
            url: "https://arxiv.org/abs/1706.03762",
            title: "Attention Is All You Need",
            sourceType: .paper,
            id: "paper-attention"
        )
        paper.author = "Ashish Vaswani et al."
        paper.journal = "NeurIPS"
        paper.publishedYear = "2017"
        paper.doi = "10.5555/3295222.3295349"
        paper.wordCount = 5_400
        try knowledgeStore.saveSource(paper)

        let associated = try store.addPaperToLecture(
            lectureID: lecture.id,
            sourceID: paper.id
        )
        #expect(associated.contains("Associated paper 'Attention Is All You Need'"))

        let item = try #require(
            knowledgeStore.loadCourseLectureItems().first {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }
        )
        #expect(item.role == .reading)

        let result = try store.getLecturePapers(lectureID: lecture.id)
        #expect(result.contains("Lecture papers (1)"))
        #expect(result.contains("course_id: \(courseID)"))
        #expect(result.contains("lecture_id: \(lecture.id)"))
        #expect(result.contains("source_id: \(paper.id)"))
        #expect(result.contains("item_id: \(item.id)"))
        #expect(result.contains("authors: Ashish Vaswani et al."))
        #expect(result.contains("venue: NeurIPS"))
        #expect(result.contains("year: 2017"))
        #expect(result.contains("doi: 10.5555/3295222.3295349"))
        #expect(result.contains("words: 5400"))
    }

    @Test("paper association is idempotent and rejects non-paper sources")
    func paperAssociationValidatesSourceTypeAndDuplicates() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let lecture = CourseSession(
            id: "lecture-1",
            courseName: "course-1",
            number: 1
        )

        try knowledgeStore.saveCourseGroup(
            name: lecture.courseName,
            metadata: CourseMetadata(title: "Course")
        )
        try knowledgeStore.saveCourseLecture(lecture)

        let paper = StudioArticle(
            url: "https://example.com/paper",
            title: "Paper",
            sourceType: .paper,
            id: "paper-1"
        )
        let article = StudioArticle(
            url: "https://example.com/article",
            title: "Article",
            sourceType: .article,
            id: "article-1"
        )
        try knowledgeStore.saveSource(paper)
        try knowledgeStore.saveSource(article)

        _ = try store.addPaperToLecture(lectureID: lecture.id, sourceID: paper.id)
        let duplicate = try store.addPaperToLecture(lectureID: lecture.id, sourceID: paper.id)
        #expect(duplicate.contains("already associated"))
        #expect(
            try knowledgeStore.loadCourseLectureItems().filter {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }.count == 1
        )

        #expect(throws: MCPError.self) {
            _ = try store.addPaperToLecture(lectureID: lecture.id, sourceID: article.id)
        }
    }

    @Test("add_paper_to_lecture's assigned_reading sets whether an attached paper is assigned reading or only cited")
    func paperAssociationSetsAssignedReading() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let lecture = CourseSession(id: "lecture-1", courseName: "course-1", number: 1)
        try knowledgeStore.saveCourseGroup(name: lecture.courseName, metadata: CourseMetadata(title: "Course"))
        try knowledgeStore.saveCourseLecture(lecture)
        let paper = StudioArticle(url: "https://example.com/paper", title: "Paper", sourceType: .paper, id: "paper-1")
        try knowledgeStore.saveSource(paper)
        func items() throws -> [CourseLectureItem] {
            try knowledgeStore.loadCourseLectureItems().filter {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }
        }

        let cited = try store.addPaperToLecture(lectureID: lecture.id, sourceID: paper.id, assignedReading: false)
        #expect(cited.contains("assigned_reading: false"))
        #expect(try items().map(\.role) == [.reference])

        // Omitted, an existing association keeps its standing.
        let again = try store.addPaperToLecture(lectureID: lecture.id, sourceID: paper.id)
        #expect(again.contains("already associated"))
        #expect(try items().map(\.role) == [.reference])

        let assigned = try store.addPaperToLecture(lectureID: lecture.id, sourceID: paper.id, assignedReading: true)
        #expect(assigned.contains("is now assigned reading"))
        #expect(try items().map(\.role) == [.reading])
        #expect(try store.getLecturePapers(lectureID: lecture.id).contains("assigned_reading: true"))
    }

    @Test("finding lecture papers fails before external work when the lecture has no readable material")
    func lecturePaperFindingRequiresReadableMaterial() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let lecture = CourseSession(
            id: "lecture-without-video",
            courseName: "course-1",
            number: 1
        )

        try knowledgeStore.saveCourseGroup(
            name: lecture.courseName,
            metadata: CourseMetadata(title: "Course")
        )
        try knowledgeStore.saveCourseLecture(lecture)

        do {
            _ = try await store.findLecturePapers(lectureID: lecture.id, force: false)
            Issue.record("Expected finding lecture papers to require readable attached material")
        } catch is MCPError {
            // Expected. No network, extraction, or model work began.
        }
    }

    @Test("lecture material chunks cover the complete text with overlap")
    func lectureMaterialChunkingIsExhaustive() {
        let content = "abcdefghijklmnopqrstuvwxyz"
        let chunks = MCPDataStore.lectureMaterialChunks(
            content,
            maxCharacters: 10,
            overlapCharacters: 2
        )

        #expect(chunks == ["abcdefghij", "ijklmnopqr", "qrstuvwxyz"])
        #expect(chunks[0].suffix(2) == chunks[1].prefix(2))
        #expect(chunks[1].suffix(2) == chunks[2].prefix(2))
    }

    /// A lecture with one video whose slides were already scanned, and one citation on
    /// it that the library already holds. Nothing in it needs the network or a model.
    private func seedScannedLecture(
        _ knowledgeStore: KnowledgeStore,
        citationStatus: VideoCitedPaper.Status = .imported
    ) throws -> (lecture: CourseSession, paper: StudioArticle, citation: VideoCitedPaper) {
        let courseID = "course-1"
        let lecture = CourseSession(
            id: "lecture-1",
            courseName: courseID,
            number: 1,
            title: "Attention"
        )
        var video = StudioArticle(
            url: "https://example.com/lecture-video",
            title: "Lecture video",
            sourceType: .video,
            id: "video-1"
        )
        video.content = "Lecture transcript without paper citations."
        let paper = StudioArticle(
            url: "https://example.com/paper",
            title: "Attention Is All You Need",
            sourceType: .paper,
            id: "paper-1"
        )

        try knowledgeStore.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(title: "Machine Learning")
        )
        try knowledgeStore.saveCourseLecture(lecture)
        try knowledgeStore.saveSource(video)
        try knowledgeStore.saveSource(paper)
        try knowledgeStore.saveCourseLectureItem(
            CourseLectureItem(
                id: "video-item",
                lectureId: lecture.id,
                sourceId: video.id,
                role: .video
            )
        )
        let citation = VideoCitedPaper(
            id: "citation-1",
            sourceID: video.id,
            title: paper.title,
            url: paper.url,
            status: citationStatus,
            importedSourceID: citationStatus == .imported ? paper.id : nil
        )
        try knowledgeStore.saveVideoCitedPaper(citation)
        return (lecture, paper, citation)
    }

    @Test("finding lecture papers reports recorded candidates without importing or attaching them")
    func lecturePaperFindingDoesNotAttach() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, paper, citation) = try seedScannedLecture(knowledgeStore)

        let result = try await store.findLecturePapers(lectureID: lecture.id, force: false)

        #expect(result.contains("\"scans_performed\" : 0"))
        #expect(result.contains("\"candidate_count\" : 1"))
        #expect(result.contains("\"cited_paper_id\" : \"\(citation.id)\""))
        #expect(result.contains("\"attached_to_lecture\" : false"))
        #expect(
            try knowledgeStore.loadCourseLectureItems().filter {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }.isEmpty
        )
    }

    @Test("ingesting chosen lecture papers attaches a held candidate to the lecture as a citation")
    func lecturePaperIngestionAttachesChosenCandidate() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, paper, citation) = try seedScannedLecture(knowledgeStore)

        let result = try await store.ingestLecturePapers(
            lectureID: lecture.id,
            citedPaperIDs: [citation.id]
        )

        #expect(result.contains("\"associated_paper_count\" : 1"))
        #expect(result.contains("\"new_library_papers\" : 0"))
        #expect(result.contains("\"source_id\" : \"\(paper.id)\""))
        let paperItems = try knowledgeStore.loadCourseLectureItems().filter {
            $0.lectureId == lecture.id && $0.sourceId == paper.id
        }
        #expect(paperItems.count == 1)
        // A paper read off the lecture's slides is only cited: it opens from
        // the video's Papers menu, not as a course row, and is not quizzed.
        #expect(paperItems.first?.role == .reference)
        #expect(result.contains("\"assigned_reading\" : false"))

        let found = try await store.findLecturePapers(lectureID: lecture.id, force: false)
        #expect(found.contains("\"attached_to_lecture\" : true"))
    }

    @Test("ingesting lecture papers attaches the ones named as assigned reading as reading, and a re-ingest never demotes")
    func lecturePaperIngestionAssignsReading() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, paper, citation) = try seedScannedLecture(knowledgeStore)

        let cited = try await store.ingestLecturePapers(lectureID: lecture.id, citedPaperIDs: [citation.id])
        #expect(cited.contains("\"assigned_reading\" : false"))

        let assigned = try await store.ingestLecturePapers(
            lectureID: lecture.id,
            citedPaperIDs: [citation.id],
            assignedReadingIDs: [citation.id]
        )
        #expect(assigned.contains("\"assigned_reading\" : true"))
        func role() throws -> CourseLectureItemRole? {
            try knowledgeStore.loadCourseLectureItems().first {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }?.role
        }
        #expect(try role() == .reading)

        _ = try await store.ingestLecturePapers(lectureID: lecture.id, citedPaperIDs: [citation.id])
        #expect(try role() == .reading)
        #expect(
            try knowledgeStore.loadCourseLectureItems().filter {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }.count == 1
        )
    }

    @Test("assigned_reading_ids outside cited_paper_ids is refused before any import")
    func lecturePaperIngestionRefusesStrayAssignedReading() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, paper, citation) = try seedScannedLecture(knowledgeStore)

        await #expect(throws: MCPError.self) {
            _ = try await store.ingestLecturePapers(
                lectureID: lecture.id,
                citedPaperIDs: [citation.id],
                assignedReadingIDs: ["citation-elsewhere"]
            )
        }
        #expect(
            try knowledgeStore.loadCourseLectureItems().filter {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }.isEmpty
        )
    }

    @Test("ingesting lecture papers requires the candidates the learner chose")
    func lecturePaperIngestionRequiresChosenCandidates() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, _, _) = try seedScannedLecture(knowledgeStore)

        await #expect(throws: MCPError.self) {
            _ = try await store.ingestLecturePapers(lectureID: lecture.id, citedPaperIDs: [])
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.ingestLecturePapers(lectureID: lecture.id, citedPaperIDs: ["  "])
        }
    }

    @Test("ingesting lecture papers refuses a candidate from outside the lecture before any import")
    func lecturePaperIngestionRefusesForeignCandidate() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, paper, citation) = try seedScannedLecture(knowledgeStore)
        var otherVideo = StudioArticle(
            url: "https://example.com/other-video",
            title: "Unrelated video",
            sourceType: .video,
            id: "video-other"
        )
        otherVideo.content = "Another transcript."
        try knowledgeStore.saveSource(otherVideo)
        try knowledgeStore.saveVideoCitedPaper(
            VideoCitedPaper(
                id: "citation-other",
                sourceID: otherVideo.id,
                title: "Some other paper",
                url: "https://example.com/other-paper"
            )
        )

        await #expect(throws: MCPError.self) {
            _ = try await store.ingestLecturePapers(
                lectureID: lecture.id,
                citedPaperIDs: [citation.id, "citation-other"]
            )
        }
        // The valid id listed first was not attached either: ids are all checked first.
        #expect(
            try knowledgeStore.loadCourseLectureItems().filter {
                $0.lectureId == lecture.id && $0.sourceId == paper.id
            }.isEmpty
        )
    }

    @Test("ingesting lecture papers skips a dismissed candidate and says why")
    func lecturePaperIngestionSkipsDismissedCandidate() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let (lecture, _, citation) = try seedScannedLecture(knowledgeStore, citationStatus: .dismissed)

        let result = try await store.ingestLecturePapers(
            lectureID: lecture.id,
            citedPaperIDs: [citation.id]
        )

        #expect(result.contains("\"associated_paper_count\" : 0"))
        #expect(result.contains("Dismissed. Restore it with update_video_cited_paper_status"))
        #expect(try knowledgeStore.loadVideoCitedPaper(id: citation.id)?.status == .dismissed)
    }

    @Test("createCourseLecture resolves one existing display title to its stable ID")
    func lectureCreationResolvesUniqueTitle() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let courseID = "course-stable-id"

        try knowledgeStore.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(
                courseCode: "CS336",
                title: "Language Modeling from Scratch",
                institution: "Stanford"
            )
        )

        let result = try store.createCourseLectureResolved(
            courseIdentifier: "  language   modeling from scratch ",
            title: "Assignment 1",
            number: nil
        )

        #expect(result.contains("course_id: \(courseID)"))
        let lectures = try knowledgeStore.loadCourseLectures()
        #expect(lectures.count == 1)
        #expect(lectures.first?.courseName == courseID)
        #expect(lectures.first?.number == 1)
    }

    @Test("ambiguous display titles fail while an exact stable ID still wins")
    func ambiguousCourseTitlesFail() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()

        try knowledgeStore.saveCourseGroup(
            name: "stanford-course",
            metadata: CourseMetadata(
                courseCode: "CS336",
                title: "Language Modeling from Scratch",
                institution: "Stanford"
            )
        )
        try knowledgeStore.saveCourseGroup(
            name: "duplicate-course",
            metadata: CourseMetadata(title: "Language Modeling from Scratch")
        )

        #expect(throws: MCPError.self) {
            _ = try store.createCourseLectureResolved(
                courseIdentifier: "Language Modeling from Scratch",
                title: "Assignment 1",
                number: nil
            )
        }

        let result = try store.createCourseLectureResolved(
            courseIdentifier: "stanford-course",
            identifierIsStableID: true,
            title: "Assignment 1",
            number: nil
        )
        #expect(result.contains("course_id: stanford-course"))
        #expect(try knowledgeStore.loadCourseLectures().first?.courseName == "stanford-course")
    }

    @Test("legacy course_name lookup does not mistake another course's ID for the title")
    func legacyCourseNameDoesNotPreferStableID() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()

        try knowledgeStore.saveCourseGroup(
            name: "Language Modeling from Scratch",
            metadata: CourseMetadata(title: "Old CS336 Materials")
        )
        try knowledgeStore.saveCourseGroup(
            name: "stanford-course-id",
            metadata: CourseMetadata(
                courseCode: "CS336",
                title: "Language Modeling from Scratch",
                institution: "Stanford"
            )
        )

        let result = try store.createCourseLectureResolved(
            courseIdentifier: "Language Modeling from Scratch",
            title: "Assignment 1",
            number: nil
        )

        #expect(result.contains("course_id: stanford-course-id"))
        #expect(try knowledgeStore.loadCourseLectures().first?.courseName == "stanford-course-id")
    }

    @Test("createCourse refuses a normalized duplicate title")
    func createCourseRejectsDuplicateTitle() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()

        try knowledgeStore.saveCourseGroup(
            name: "existing-course",
            metadata: CourseMetadata(
                courseCode: "CS336",
                title: "Language Modeling from Scratch",
                institution: "Stanford"
            )
        )

        #expect(throws: MCPError.self) {
            _ = try store.createCourse(
                title: "  language   modeling FROM scratch ",
                courseCode: nil,
                institution: nil,
                instructors: nil
            )
        }

        let created = try store.createCourse(
            title: "Deep Learning",
            courseCode: "CS230",
            institution: "Stanford",
            instructors: nil
        )
        #expect(created.contains("Created course 'Deep Learning'"))
        let groups = try knowledgeStore.loadCourseGroups()
        #expect(groups.values.contains { $0.title == "Deep Learning" })
    }

    @Test("course parent-group resolution rejects ambiguous titles")
    func courseSourceGroupingRejectsAmbiguousTitles() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()

        try knowledgeStore.saveCourseGroup(
            name: "course-one",
            metadata: CourseMetadata(title: "Duplicate Course")
        )
        try knowledgeStore.saveCourseGroup(
            name: "course-two",
            metadata: CourseMetadata(title: "Duplicate Course")
        )

        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: "https://example.com/homework",
                title: "Homework",
                sourceType: "course",
                content: "Homework content",
                parentGroup: "Duplicate Course",
                author: nil
            )
        }
    }

    @Test("updateCourse changes metadata only for an exact stable ID")
    func updateCourseMetadata() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let courseID = "stanford-cs336"

        try knowledgeStore.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(title: "Language Modeling from Scratch")
        )

        #expect(throws: MCPError.self) {
            _ = try store.updateCourse(
                courseID: "Language Modeling from Scratch",
                title: nil,
                courseCode: "CS336",
                institution: nil,
                instructors: nil,
                playlistURL: nil
            )
        }

        let result = try store.updateCourse(
            courseID: courseID,
            title: nil,
            courseCode: "CS336",
            institution: "Stanford",
            instructors: "Tatsunori Hashimoto; Percy Liang",
            playlistURL: "https://www.youtube.com/playlist?list=cs336"
        )

        #expect(result.contains("course_code, institution, instructors, playlist_url"))
        let metadata = try knowledgeStore.loadCourseGroups()[courseID]
        #expect(metadata?.title == "Language Modeling from Scratch")
        #expect(metadata?.courseCode == "CS336")
        #expect(metadata?.institution == "Stanford")
        #expect(metadata?.instructors == "Tatsunori Hashimoto; Percy Liang")
        #expect(metadata?.playlistURL == "https://www.youtube.com/playlist?list=cs336")
    }

    @Test("deleteCourse requires a stable ID, keeps a video and hides course-only material")
    func deleteCoursePreservesSources() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()
        let courseID = "stanford-cs336"

        try knowledgeStore.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(
                courseCode: "CS336",
                title: "Language Modeling from Scratch",
                institution: "Stanford"
            )
        )
        let lecture = CourseSession(
            id: "lecture-1",
            courseName: courseID,
            number: 1,
            title: "Assignment 1"
        )
        try knowledgeStore.saveCourseLecture(lecture)

        var source = StudioArticle(
            url: "https://example.com/assignment-1",
            title: "Assignment 1",
            sourceType: .course,
            id: "assignment-1"
        )
        source.parentGroup = courseID
        source.content = "Assignment text"
        source.wordCount = 2
        source.state = .ready
        try knowledgeStore.saveSource(source)
        try knowledgeStore.saveCourseLectureItem(
            CourseLectureItem(
                id: "lecture-item-1",
                lectureId: lecture.id,
                sourceId: source.id,
                role: .exercise
            )
        )

        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=lecture-1",
            title: "Lecture 1",
            sourceType: .video,
            id: "lecture-video-1"
        )
        video.content = "Transcript"
        video.wordCount = 1
        video.state = .ready
        try knowledgeStore.saveSource(video)
        try knowledgeStore.saveCourseLectureItem(
            CourseLectureItem(
                id: "lecture-item-2",
                lectureId: lecture.id,
                sourceId: video.id,
                role: .video
            )
        )

        #expect(throws: MCPError.self) {
            _ = try store.deleteCourse(courseID: "Language Modeling from Scratch")
        }

        let result = try store.deleteCourse(courseID: courseID)
        // The lecture video keeps its own library home; the assignment PDF had
        // none but the course, so it is hidden rather than left where no list
        // can show it.
        #expect(result.contains("Preserved 1 source"))
        #expect(result.contains("Hid 1 course source"))
        #expect(try knowledgeStore.loadCourseGroups()[courseID] == nil)
        #expect(try knowledgeStore.loadCourseLectures().isEmpty)
        #expect(try knowledgeStore.loadCourseLectureItems().isEmpty)

        let active = try knowledgeStore.loadActiveSources()
        let preservedVideo = active.first { $0.id == video.id }
        #expect(preservedVideo != nil)
        #expect(preservedVideo?.isHidden == false)
        let hiddenMaterial = active.first { $0.id == source.id }
        #expect(hiddenMaterial != nil)
        #expect(hiddenMaterial?.status == .active)
        #expect(hiddenMaterial?.isHidden == true)
        #expect(hiddenMaterial?.parentGroup == nil)
        // Hidden, not archived: the text is still there to come back to.
        #expect(try knowledgeStore.loadSourceContent(source.id) == "Assignment text")
    }

    // MARK: - Playlist courses (2026-09-26)

    @Test("add_source refuses a YouTube playlist and names import_youtube_playlist")
    func addSourceRefusesPlaylist() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }

        // An assistant told to ingest a playlist filed its page as a course
        // source and built the course by hand. The page is never a source.
        for sourceType in ["course", "video", "article"] {
            do {
                _ = try store.addSource(
                    url: "https://www.youtube.com/playlist?list=PLDElI2mHSO2_MeI92yIVyrs3CWxnqORhy",
                    title: "Mitochondrial Bioenergetics Graduate Course",
                    sourceType: sourceType,
                    content: "PLAY ALL",
                    parentGroup: sourceType == "course" ? "Mitochondrial Bioenergetics Graduate Course" : nil,
                    author: nil
                )
                Issue.record("add_source accepted a playlist as \(sourceType)")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("import_youtube_playlist"))
            }
        }
        #expect(try store.knowledgeStore().loadActiveSources().isEmpty)
        #expect(try store.knowledgeStore().loadCourseGroups().isEmpty)

        let batch = try store.addSources(
            [["url": "https://www.youtube.com/playlist?list=PL123", "title": "A playlist", "source_type": "course", "parent_group": "Course"]],
            connectorLabel: nil
        )
        #expect(batch.contains("import_youtube_playlist"))
        #expect(try store.knowledgeStore().loadActiveSources().isEmpty)
    }

    @Test("a course add_source names for the first time gets a UUID, not its title")
    func addSourceMintsStableCourseID() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let knowledgeStore = try store.knowledgeStore()

        _ = try store.addSource(
            url: "/path/to/handout-1.pdf",
            title: "Handout 1",
            sourceType: "course",
            content: "One.",
            parentGroup: "Cell Biology",
            author: nil
        )
        let groups = try knowledgeStore.loadCourseGroups()
        #expect(groups.count == 1)
        let courseID = try #require(groups.keys.first)
        #expect(courseID != "Cell Biology")
        #expect(UUID(uuidString: courseID) != nil)
        #expect(groups[courseID]?.title == "Cell Biology")

        // The title keeps resolving to that course rather than minting another.
        _ = try store.addSource(
            url: "/path/to/handout-2.pdf",
            title: "Handout 2",
            sourceType: "course",
            content: "Two.",
            parentGroup: "Cell Biology",
            author: nil
        )
        #expect(try knowledgeStore.loadCourseGroups().count == 1)
        let parents = Set(try knowledgeStore.loadActiveSources().compactMap(\.parentGroup))
        #expect(parents == [courseID])
    }

    @Test("a playlist resolves to the one course that already names it")
    func playlistResolvesToExistingCourse() {
        let groups: [String: CourseMetadata] = [
            "course-a": CourseMetadata(title: "A", playlistURL: "https://www.youtube.com/playlist?list=PLaaa"),
            "course-b": CourseMetadata(title: "B", playlistURL: "https://youtube.com/playlist?list=PLbbb&si=share"),
            "course-c": CourseMetadata(title: "C"),
        ]
        #expect(MCPDataStore.courseID(forPlaylistURL: "https://www.youtube.com/playlist?list=PLbbb", in: groups) == "course-b")
        #expect(MCPDataStore.courseID(forPlaylistURL: "https://m.youtube.com/playlist?list=PLaaa&index=2", in: groups) == "course-a")
        #expect(MCPDataStore.courseID(forPlaylistURL: "https://www.youtube.com/playlist?list=PLzzz", in: groups) == nil)

        // Two courses naming one playlist is not a choice to make silently.
        var duplicated = groups
        duplicated["course-d"] = CourseMetadata(title: "D", playlistURL: "https://www.youtube.com/playlist?list=PLaaa")
        #expect(MCPDataStore.courseID(forPlaylistURL: "https://www.youtube.com/playlist?list=PLaaa", in: duplicated) == nil)
    }

    @Test("import_youtube_playlist is registered, open-world, and refuses a non-playlist url")
    func playlistImportToolContract() async throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "import_youtube_playlist" })
        #expect(tool.inputSchema["required"] as? [String] == ["url"])
        #expect(MCPToolRegistry.annotations(for: "import_youtube_playlist")["openWorldHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "import_youtube_playlist")["readOnlyHint"] as? Bool == false)

        let (store, path) = try makeStore()
        defer { cleanup(path) }
        await #expect(throws: MCPError.self) {
            _ = try await store.importYouTubePlaylistMCP(url: "https://www.youtube.com/watch?v=abc", courseID: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.importYouTubePlaylistMCP(
                url: "https://www.youtube.com/playlist?list=PL123",
                courseID: "no-such-course"
            )
        }
    }
}

#endif
