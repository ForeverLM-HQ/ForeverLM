import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ForeverLM

#if os(macOS)

// MARK: - Fixtures

private enum HomingMCPFixtures {
    static func makeStore() throws -> (MCPDataStore, KnowledgeStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_homing_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), directory)
    }

    @discardableResult
    static func notebook(_ store: KnowledgeStore, _ title: String, sources: [String] = [], teamID: String? = nil) throws -> LearningGoalRecord {
        try store.createCompanionGoal(
            title: title, topic: title, startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: sources, teamID: teamID
        )
    }

    static func source(_ store: KnowledgeStore, _ id: String, content: String = "Sleep pressure rises across the day.") throws {
        var article = StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, id: id)
        article.content = content
        article.state = .ready
        try store.saveSource(article)
    }

    static func team(_ store: KnowledgeStore, id: String = "team-1", permission: TeamPermission = .readWrite) throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: id, name: "Nexus", role: .owner, permission: permission, zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: id), zoneOwnerRecordName: nil, shareRecordName: nil,
            shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        )
        try store.saveTeam(team)
        return team
    }

    static func picture() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.4, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func imageID(in text: String) throws -> String {
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("image_id: ") })
        return String(line.dropFirst("image_id: ".count))
    }
}

// MARK: - notebook_id on the makers and the lists

/// Over MCP a maker's notebook_id files what it makes in that Notebook, and a
/// list's keeps what belongs to it by the notebook rule; never inferred, and
/// checked before anything is made (docs/notebooks-design.md, "Homing").
@Suite("Homing over MCP")
struct NotebookHomingMCPTests {
    fileprivate typealias F = HomingMCPFixtures

    @Test("Every maker and list named in the homing plan offers notebook_id, never as required")
    func schemasOfferNotebookID() {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let names = [
            "generate_image", "save_image", "generate_course", "create_course", "import_youtube_playlist",
            "import_teachable_course", "generate_explainer_video", "update_course",
            "list_animations", "list_walkthroughs", "list_courses", "list_ideas", "list_images", "list_docs",
        ]
        for name in names {
            let tool = tools.first { $0.name == name }
            let properties = tool?.inputSchema["properties"] as? [String: Any]
            #expect(properties?["notebook_id"] != nil, "\(name)")
            #expect((tool?.inputSchema["required"] as? [String] ?? []).contains("notebook_id") == false, "\(name)")
        }
    }

    @Test("list_courses names the Notebooks that follow each course and keeps the ones a Notebook follows")
    func listCourses() throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveCourseGroup(name: "course-first", metadata: CourseMetadata(title: "First followed"))
        try store.saveCourseGroup(name: "course-second", metadata: CourseMetadata(title: "Second followed"))
        try store.saveCourseGroup(name: "course-loose", metadata: CourseMetadata(title: "Loose"))
        let first = try F.notebook(store, "First")
        let second = try F.notebook(store, "Second")
        try store.linkCourseToNotebook(goalID: first.id, courseID: "course-first", sourceIDs: [])
        try store.linkCourseToNotebook(goalID: second.id, courseID: "course-second", sourceIDs: [])
        try store.linkCourseToNotebook(goalID: second.id, courseID: "course-first", sourceIDs: [])

        let all = try mcp.listCourses()
        #expect(all.contains("Courses (3):"))
        #expect(all.contains("followed_by_notebook_ids: \(first.id),\(second.id)") || all.contains("followed_by_notebook_ids: \(second.id),\(first.id)"))
        #expect(!all.contains("notebook_id:"), "a course lives in no Notebook, so none is named as its own")

        let inFirst = try mcp.listCourses(notebookID: first.id)
        #expect(inFirst.contains("Courses in Notebook \(first.id) (1):"))
        #expect(inFirst.contains("First followed"))
        #expect(!inFirst.contains("Second followed") && !inFirst.contains("Loose"))

        let inSecond = try mcp.listCourses(notebookID: second.id)
        #expect(inSecond.contains("First followed") && inSecond.contains("Second followed") && !inSecond.contains("Loose"))

        let detail = try mcp.getCourse(courseIdentifier: "course-second")
        #expect(detail.contains("followed_by: \(second.id) (‘Second’)"))
        #expect(try mcp.getCourse(courseIdentifier: "course-loose").contains("followed_by: none"))
        #expect(throws: (any Error).self) { try mcp.listCourses(notebookID: "not-a-notebook") }
    }

    @Test("create_course lets the Notebook named follow it; update_course links another and unlink_notebook_id stops one")
    func createAndFollowCourse() throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try F.notebook(store, "First")
        let second = try F.notebook(store, "Second")

        let created = try mcp.createCourse(title: "Bioenergetics", courseCode: nil, institution: nil, instructors: nil, notebookID: first.id)
        #expect(created.contains("notebook_id_applied: \(first.id)"))
        #expect(created.contains("lives in no Notebook"))
        let courseID = try #require(try store.loadCourseGroups().first { $0.value.title == "Bioenergetics" }?.key)
        // The new course's id rides on its own line, never beside its title.
        #expect(created.hasPrefix("Created course 'Bioenergetics'.\ncourse_id: \(courseID)\n"))
        #expect(try store.notebookIDsFollowingCourse(courseID) == [first.id])

        let linked = try mcp.updateCourse(courseID: courseID, title: nil, courseCode: nil, institution: nil, instructors: nil, playlistURL: nil, notebookID: second.id)
        #expect(linked.contains("Notebook ‘Second’"))
        #expect(linked.contains("follows the course now"))
        #expect(Set(try store.notebookIDsFollowingCourse(courseID)) == [first.id, second.id], "following adds; nothing moves")

        let unlinked = try mcp.updateCourse(courseID: courseID, title: nil, courseCode: nil, institution: nil, instructors: nil, playlistURL: nil, notebookID: nil, unlinkNotebookID: first.id)
        #expect(unlinked.contains("no longer follows the course"))
        #expect(try store.notebookIDsFollowingCourse(courseID) == [second.id])

        // An empty notebook_id is an unused slot, not a request.
        #expect(throws: (any Error).self) {
            try mcp.updateCourse(courseID: courseID, title: nil, courseCode: nil, institution: nil, instructors: nil, playlistURL: nil, notebookID: "")
        }

        let loose = try mcp.createCourse(title: "Loose", courseCode: nil, institution: nil, instructors: nil)
        #expect(loose.contains("notebook_id_applied: none"))
    }

    @Test("A course is refused before it is made for an archived Notebook or a team's")
    func courseRefusals() async throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = try F.notebook(store, "Archived")
        try store.setLearningGoalStatus(goalID: archived.id, status: .archived)
        let team = try F.team(store)
        let teamNotebook = try F.notebook(store, "Team's", teamID: team.id)

        #expect(throws: (any Error).self) {
            try mcp.createCourse(title: "One", courseCode: nil, institution: nil, instructors: nil, notebookID: archived.id)
        }
        #expect(throws: (any Error).self) {
            try mcp.createCourse(title: "Two", courseCode: nil, institution: nil, instructors: nil, notebookID: teamNotebook.id)
        }
        #expect(try store.loadCourseGroups().isEmpty, "nothing was made")

        // generate_course checks its Notebook before any model is asked.
        await #expect(throws: (any Error).self) {
            _ = try await mcp.generateCourse(
                topic: "t", learnerNotes: nil, useWeb: false, moduleCount: nil, scheduleStart: nil,
                daysPerModule: nil, notebookID: teamNotebook.id
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await mcp.generateCourse(
                topic: "t", learnerNotes: nil, useWeb: false, moduleCount: nil, scheduleStart: nil,
                daysPerModule: nil, notebookID: archived.id
            )
        }
        // And generate_explainer_video before the price is asked.
        await #expect(throws: (any Error).self) {
            _ = try await mcp.generateExplainerVideo(arguments: ["concept": "proton pumping", "notebook_id": archived.id])
        }
    }

    @Test("A course import's Notebook is checked against the course's library before anything is imported")
    func importsRefuseAnotherLibrarysNotebook() async throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let team = try F.team(store)
        let teamNotebook = try F.notebook(store, "Team's", teamID: team.id)
        let mine = try F.notebook(store, "Mine")
        try store.execForTesting("INSERT INTO courses (id, title, team_id) VALUES ('team-course', 'Team Course', '\(team.id)')")
        func refusal(_ call: () async throws -> String) async -> String? {
            do {
                _ = try await call()
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        // A new course is My Library's: a team's Notebook is refused before
        // the playlist or the outline is read (no studio is reached here).
        let playlist = await refusal {
            try await mcp.importYouTubePlaylistMCP(url: "https://www.youtube.com/playlist?list=PLhoming", courseID: nil, notebookID: teamNotebook.id)
        }
        #expect(playlist?.contains("is a team's Notebook") == true, "\(playlist ?? "no refusal")")
        #expect(playlist?.contains("Nothing was imported.") == true)
        let teachable = await refusal {
            try await mcp.importTeachableCourseMCP(url: "https://school.teachable.com/courses/biology/lectures/123", courseID: nil, notebookID: teamNotebook.id)
        }
        #expect(teachable?.contains("Nothing was imported.") == true, "\(teachable ?? "no refusal")")
        // A team's course lives only in one of that team's Notebooks.
        let intoTeamCourse = await refusal {
            try await mcp.importYouTubePlaylistMCP(url: "https://www.youtube.com/playlist?list=PLhoming", courseID: "team-course", notebookID: mine.id)
        }
        #expect(intoTeamCourse?.contains("is team \(team.id)'s") == true, "\(intoTeamCourse ?? "no refusal")")
        #expect(try store.loadCourseGroups().keys.sorted() == ["team-course"], "nothing was imported")
        #expect(try store.linkedCourseIDsForNotebook(goalID: teamNotebook.id).isEmpty)
    }

    @Test("A link update_course refuses leaves the course's metadata as it was")
    func refusedLinkWritesNothing() throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveCourseGroup(name: "course-1", metadata: CourseMetadata(title: "Bioenergetics"))
        let team = try F.team(store)
        let teamNotebook = try F.notebook(store, "Team's", teamID: team.id)

        #expect(throws: (any Error).self) {
            try mcp.updateCourse(courseID: "course-1", title: "Renamed", courseCode: nil, institution: nil, instructors: nil, playlistURL: nil, notebookID: teamNotebook.id)
        }
        #expect(try store.loadCourseGroups()["course-1"]?.title == "Bioenergetics", "the title waits on the link")
        #expect(try store.notebookIDsFollowingCourse("course-1").isEmpty)
    }

    @Test("list_ideas keeps the Ideas linked to a Notebook or to one of its Goals")
    func listIdeas() throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = try F.notebook(store, "Notebook")
        let other = try F.notebook(store, "Other")
        let goal = try store.createCompanionGoal(
            title: "Finish", topic: "t", startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        _ = try store.createIdea(title: "Linked to the notebook", links: [IdeaLink(kind: .notebook, targetID: notebook.id)])
        _ = try store.createIdea(title: "Linked to its Goal", links: [IdeaLink(kind: .goal, targetID: goal.id)])
        _ = try store.createIdea(title: "Linked elsewhere", links: [IdeaLink(kind: .notebook, targetID: other.id)])
        _ = try store.createIdea(title: "Loose")

        let listed = try mcp.listIdeas(includeArchived: true, notebookID: notebook.id)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        let titles = Set(((object["ideas"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String })
        #expect(titles == ["Linked to the notebook", "Linked to its Goal"])
        #expect(object["notebook_id"] as? String == notebook.id)
        #expect(try mcp.listIdeas(includeArchived: true).contains("Loose"))
    }

    @Test("list_animations keeps the animations filed in a Notebook, not the ones that only explain its sources")
    func listAnimations() async throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try F.source(store, "src-1")
        let notebook = try F.notebook(store, "Notebook", sources: ["src-1"])
        let now = Date()
        for (id, home, links) in [("homed", notebook.id, [notebook.id]), ("linked", nil, [notebook.id]), ("explains-only", nil, [String]())] as [(String, String?, [String])] {
            try store.saveArtifactRecord(ArtifactRecord(
                id: id, title: id, homeNotebookID: home, linkedNotebookIDs: links,
                linkedURL: "foreverlm-site://\(id)/", kind: .animation, sourceIDs: ["src-1"], createdAt: now, updatedAt: now
            ))
        }
        let listed = try await mcp.listAnimations(sourceID: nil, notebookID: notebook.id)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        let ids = Set(((object["animations"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        #expect(ids == ["homed", "linked"])
        #expect(object["scope"] as? String == "notebook")
        #expect(object["animation_count"] as? Int == 2)
    }

    @Test("list_walkthroughs keeps the walks of a Notebook's sources, a team Notebook's copy included")
    func listWalkthroughs() async throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Sleep pressure rises across the day."
        try F.source(store, "src-in", content: text)
        try F.source(store, "src-out", content: text)
        for sourceID in ["src-in", "src-out"] {
            try store.savePaperWalkthrough(PaperWalkthrough(
                sourceID: sourceID,
                sourceSHA256: PaperContentPreparationService.sha256(text),
                title: "Walk of \(sourceID)",
                steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "T", body: "B", anchor: PaperWalkthroughAnchor(passage: "Sleep pressure rises"))],
                author: .app
            ))
        }
        let notebook = try F.notebook(store, "Notebook", sources: ["src-in"])
        func walked(_ notebookID: String) async throws -> Set<String> {
            let listed = try await mcp.listWalkthroughs(notebookID: notebookID)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
            return Set(((object["walkthroughs"] as? [[String: Any]]) ?? []).compactMap { $0["source_id"] as? String })
        }
        #expect(try await walked(notebook.id) == ["src-in"])

        // A team notebook holds the team's copy; the walk rides the own row.
        let team = try F.team(store)
        let copyID = try store.copySourceIntoTeam(sourceID: "src-out", teamID: team.id) { $0 }
        let teamNotebook = try F.notebook(store, "Team notebook", teamID: team.id)
        _ = try store.addCompanionSeedSources(goalID: teamNotebook.id, sourceIDs: [copyID])
        #expect(try await walked(teamNotebook.id) == ["src-out"])
    }

    @Test("A picture saved into a Notebook lives there, keeps it through revisions, and lists under it")
    func imagesLiveInANotebook() async throws {
        let (mcp, store, root) = try F.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = try F.notebook(store, "Notebook")
        let other = try F.notebook(store, "Other")
        let archived = try F.notebook(store, "Archived")
        try store.setLearningGoalStatus(goalID: archived.id, status: .archived)
        let png = try F.picture().base64EncodedString()

        let refused = await mcp.saveImage(arguments: ["prompt": "x", "title": "Refused", "image_base64": png, "notebook_id": archived.id])
        #expect(refused.isError)
        #expect(refused.text.contains("archived"))

        let saved = await mcp.saveImage(arguments: ["prompt": "A cristae diagram", "title": "Cristae", "image_base64": png, "notebook_id": notebook.id])
        #expect(!saved.isError, "\(saved.text)")
        let imageID = try F.imageID(in: saved.text)
        defer {
            if let group = GeneratedImageStore.group(containing: imageID) {
                for version in group.versions { try? FileManager.default.removeItem(atPath: version.path) }
            }
        }
        #expect(saved.text.contains("Notebook: \(notebook.id)"))
        #expect(GeneratedImageStore.group(containing: imageID)?.notebookID == notebook.id)

        let revised = await mcp.saveImage(arguments: [
            "prompt": "A cristae diagram, labelled", "image_base64": png, "revises": imageID, "notebook_id": other.id,
        ])
        #expect(!revised.isError, "\(revised.text)")
        #expect(GeneratedImageStore.group(containing: imageID)?.versions.allSatisfy { $0.details?.notebookID == notebook.id } == true,
                "an image lives in one Notebook from the day it is made")

        let inNotebook = await mcp.listImages(arguments: ["notebook_id": notebook.id, "limit": 100])
        #expect(inNotebook.text.contains("image_id \(imageID)"))
        let inOther = await mcp.listImages(arguments: ["notebook_id": other.id, "limit": 100])
        #expect(!inOther.text.contains("image_id \(imageID)"))
        let unknown = await mcp.listImages(arguments: ["notebook_id": "not-a-notebook"])
        #expect(unknown.isError)
    }
}

// MARK: - A Notebook chat's made things

/// What a Notebook's chat makes is filed in its notebook when the model left
/// the notebook out — only where the notebook takes it — and the prompt says
/// where it goes (`ReviewSessionManager.notebookScopedArguments`).
@Suite("A Notebook chat's made things")
@MainActor
struct NotebookChatMadeThingTests {
    @Test("Each maker's notebook argument is filled in when left out, and a named one is kept")
    func makersAreFilled() {
        func filled(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
            ReviewSessionManager.notebookScopedArgumentsForTesting(toolName: tool, arguments: arguments, notebookScopeID: "proj-1")
        }
        for tool in ["create_doc", "link_page", "link_google_doc", "save_site", "save_animation"] {
            #expect(filled(tool, ["title": "T"])["home_notebook_id"] as? String == "proj-1", "\(tool)")
            #expect(filled(tool, ["home_notebook_id": "proj-2"])["home_notebook_id"] as? String == "proj-2", "\(tool)")
            #expect(filled(tool, ["notebook_ids": ["proj-3"]])["home_notebook_id"] == nil, "\(tool): links the model chose stand")
        }
        #expect(filled("save_site", ["site": "site-1"])["home_notebook_id"] == nil, "an update keeps where the site lives")
        #expect(filled("save_animation", ["animation": "anim-1"])["home_notebook_id"] == nil)
        for tool in ["generate_course", "create_course", "import_youtube_playlist", "import_teachable_course", "create_learning_goal"] {
            #expect(filled(tool, ["topic": "t"])["notebook_id"] as? String == "proj-1", "\(tool)")
            #expect(filled(tool, ["notebook_id": " "])["notebook_id"] as? String == "proj-1", "\(tool): blank is left out")
            #expect(filled(tool, ["notebook_id": "proj-2"])["notebook_id"] as? String == "proj-2", "\(tool)")
        }
        #expect(filled("generate_explainer_video", ["concept": "c"])["notebook_id"] as? String == "proj-1")
        #expect(filled("generate_explainer_video", ["concept": "c", "source_id": "src-1"])["notebook_id"] == nil, "a source's video rides it")
        #expect(filled("generate_explainer_video", ["concept": "c", "lecture_id": "lec-1"])["notebook_id"] == nil)

        let idea = filled("create_idea", ["title": "A thought"])["links"] as? [[String: Any]]
        #expect(idea?.count == 1)
        #expect(idea?.first?["kind"] as? String == "notebook")
        #expect(idea?.first?["target_id"] as? String == "proj-1")
        let goalLinked = filled("create_idea", ["title": "A thought", "links": [["kind": "goal", "target_id": "goal-9"]]])["links"] as? [[String: Any]]
        #expect(goalLinked?.count == 1, "an Idea filed already keeps its filing")
        // Anything else passes through untouched.
        #expect(filled("search_sources_keyword", ["query": "q"]).count == 1)

        // A team's notebook files no course: a course is made in My Library.
        let team = ReviewSessionManager.MadeThingFiling(notebookID: "proj-1", filing: .files, teamID: "team-1")
        for tool in ["generate_course", "create_course", "import_youtube_playlist", "import_teachable_course"] {
            let arguments = ReviewSessionManager.notebookScopedArgumentsForTesting(
                toolName: tool, arguments: ["topic": "t"], notebookScopeID: "proj-1", madeThingFiling: .some(team)
            )
            #expect(arguments["notebook_id"] == nil, "\(tool)")
        }
        let teamDoc = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "create_doc", arguments: ["title": "T"], notebookScopeID: "proj-1", madeThingFiling: .some(team)
        )
        #expect(teamDoc["home_notebook_id"] as? String == "proj-1")
    }

    @Test("A notebook that takes nothing new, or one not yet read, has nothing filled in")
    func notFilledWhereNothingCanLand() {
        typealias Filing = ReviewSessionManager.NotebookImportFiling
        for filing in [Filing.libraryOnly(.archived), .libraryOnly(.readOnlyTeam(teamName: "Theirs"))] {
            let arguments = ReviewSessionManager.notebookScopedArgumentsForTesting(
                toolName: "create_doc", arguments: ["title": "T"], notebookScopeID: "proj-1",
                madeThingFiling: .some(ReviewSessionManager.MadeThingFiling(notebookID: "proj-1", filing: filing))
            )
            #expect(arguments["home_notebook_id"] == nil, "\(filing)")
        }
        let unread = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "generate_course", arguments: ["topic": "t"], notebookScopeID: "proj-1", madeThingFiling: .some(nil)
        )
        #expect(unread["notebook_id"] == nil)
    }

    @Test("The prompt says where what the chat makes is filed")
    func promptSaysWhereThingsGo() {
        let tools = ["create_doc", "generate_course"].map {
            ReviewSessionManager.AppToolDefinition(name: $0, description: $0, inputSchemaJSON: "{\"type\":\"object\"}")
        }
        let files = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria", hasAttachedSource: true, appTools: tools, notebookScopeID: "proj-1"
        )
        #expect(files.contains("is filed in this Notebook. Leave home_notebook_id and notebook_id out"))
        let closed = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria", hasAttachedSource: true, appTools: tools, notebookScopeID: "proj-1",
            importFiling: .libraryOnly(.archived)
        )
        #expect(closed.contains("What you make here is filed in no Notebook: this Notebook takes nothing new, because it is archived."))
        #expect(!closed.contains("Leave home_notebook_id and notebook_id out"))
        let outside = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria", hasAttachedSource: true, appTools: tools
        )
        #expect(!outside.contains("What you make here"))
        let teams = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria", hasAttachedSource: true, appTools: tools, notebookScopeID: "proj-1",
            madeThingFiling: .some(ReviewSessionManager.MadeThingFiling(notebookID: "proj-1", filing: .files, teamID: "team-1"))
        )
        #expect(teams.contains("A course is made in the learner's own library, in no Notebook: this Notebook is a team's."))
        #expect(!teams.contains("a Doc, a site or an animation, a course,"))
    }

    @Test("A Goal's chat files what it makes in the Goal's Notebook; a Goal standing alone files nothing")
    func goalChatsFileInTheirNotebook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookChatMadeThingTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let notebook = try await storage.createCompanionGoal(
            title: "Notebook", topic: "n", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let nested = try await storage.createCompanionGoal(
            title: "Finish", topic: "f", startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let alone = try await storage.createCompanionGoal(
            title: "Alone", topic: "a", startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: []
        )

        let inGoal = await ReviewSessionManager.notebookChatMadeThingTurnForTesting(
            storage: storage, notebookScopeID: nested.id, toolName: "create_doc", arguments: ["title": "Notes"]
        )
        #expect(inGoal.filing == ReviewSessionManager.MadeThingFiling(notebookID: notebook.id, filing: .files))
        #expect(inGoal.arguments["home_notebook_id"] as? String == notebook.id)
        #expect(inGoal.prompt.contains("the Notebook this chat's Goal belongs to (notebook_id \"\(notebook.id)\")"))

        let standalone = await ReviewSessionManager.notebookChatMadeThingTurnForTesting(
            storage: storage, notebookScopeID: alone.id, toolName: "create_doc", arguments: ["title": "Notes"]
        )
        #expect(standalone.filing == nil)
        #expect(standalone.arguments["home_notebook_id"] == nil)

        let inNotebook = await ReviewSessionManager.notebookChatMadeThingTurnForTesting(
            storage: storage, notebookScopeID: notebook.id, toolName: "generate_course", arguments: ["topic": "t"]
        )
        #expect(inNotebook.arguments["notebook_id"] as? String == notebook.id)

        try await storage.setLearningGoalStatus(goalID: notebook.id, status: .archived)
        let archived = await ReviewSessionManager.notebookChatMadeThingTurnForTesting(
            storage: storage, notebookScopeID: notebook.id, toolName: "generate_course", arguments: ["topic": "t"]
        )
        #expect(archived.filing == ReviewSessionManager.MadeThingFiling(notebookID: notebook.id, filing: .libraryOnly(.archived)))
        #expect(archived.arguments["notebook_id"] == nil)
    }
}

#endif
