// MCPDataStoreTests: Ideas, directions, Goals and Notebook-scoped tools.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    // MARK: - Ideas (docs/ideas-design.md)

    /// The Ideas tab over MCP: jot one down, link what it draws on, read it
    /// back with the links resolved, and put it away rather than lose it.
    @Test("The Ideas tools jot, link, list, archive and delete, and refuse a link to nothing")
    func ideaToolsOverMCP() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        for name in ["list_ideas", "create_idea", "update_idea", "link_idea", "unlink_idea", "delete_idea"] {
            #expect(MCPToolRegistry.shared.tools.contains { $0.name == name }, "\(name) is not registered")
        }

        try Self.seedReadySource(
            knowledge, id: "idea-source", url: "https://example.com/idea-source",
            title: "Mitochondrial origins of the pressure to sleep", sourceType: .article
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Write the sleep-pressure piece", description: nil, topic: "sleep pressure",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        let created = try parseJSON(try store.createIdea(
            title: "  Field effects might explain\n  the sleep pressure curve  ",
            notes: "Worth a look before the piece.",
            links: [["kind": "source", "target_id": "idea-source"]]
        ))
        #expect(created["status"] as? String == "created")
        #expect(created["title"] as? String == "Field effects might explain the sleep pressure curve", "the words are kept, collapsed to one line")
        #expect(created["linked"] as? Int == 1)
        let ideaID = try #require(created["idea_id"] as? String)

        let linked = try parseJSON(try store.linkIdea(ideaID: ideaID, kindString: "goal", targetIDs: [goal.id]))
        #expect(linked["added"] as? Int == 1)
        let repeated = try parseJSON(try store.linkIdea(ideaID: ideaID, kindString: "goal", targetIDs: [goal.id]))
        #expect(repeated["added"] as? Int == 0 && repeated["already_linked"] as? Int == 1)

        let listed = try parseJSON(try store.listIdeas(includeArchived: true))
        let rows = try #require(listed["ideas"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["notes"] as? String == "Worth a look before the piece.")
        let links = try #require(rows[0]["links"] as? [[String: Any]])
        #expect(links.count == 2)
        let sourceLink = try #require(links.first { $0["kind"] as? String == "source" })
        #expect(sourceLink["title"] as? String == "Mitochondrial origins of the pressure to sleep", "a link reads as what it points at")
        let goalLink = try #require(links.first { $0["kind"] as? String == "goal" })
        #expect(goalLink["title"] as? String == "Write the sleep-pressure piece")

        do {
            _ = try store.linkIdea(ideaID: ideaID, kindString: "source", targetIDs: ["no-such-source"])
            Issue.record("a link to nothing went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("no-such-source"))
        }
        do {
            _ = try store.linkIdea(ideaID: ideaID, kindString: "sculpture", targetIDs: ["idea-source"])
            Issue.record("an unknown kind went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("kind must be one of"))
        }
        #expect(try #require(try knowledge.loadIdea(ideaID)).links.count == 2, "a refused link writes nothing")

        let unlinked = try parseJSON(try store.unlinkIdea(ideaID: ideaID, kindString: "goal", targetIDs: [goal.id]))
        #expect(unlinked["removed"] as? Int == 1 && unlinked["links"] as? Int == 1)

        let archived = try parseJSON(try store.updateIdea(ideaID: ideaID, title: nil, notes: "", statusString: "archived"))
        #expect(archived["idea_status"] as? String == "archived")
        #expect(archived["has_notes"] as? Bool == false, "an empty note clears it")
        let openOnly = try parseJSON(try store.listIdeas(includeArchived: false))
        #expect((openOnly["ideas"] as? [[String: Any]])?.isEmpty == true)
        do {
            _ = try store.updateIdea(ideaID: ideaID, title: "   ", notes: nil, statusString: nil)
            Issue.record("an Idea was left without words")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("delete_idea"))
        }

        let deleted = try parseJSON(try store.deleteIdea(ideaID: ideaID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["links_dropped"] as? Int == 1)
        #expect(try knowledge.loadIdea(ideaID) == nil)
        #expect(try knowledge.sourceExists("idea-source"), "the source it named stays in the library")
        #expect(try knowledge.loadLearningGoal(goal.id) != nil, "so does the Goal")
        do {
            _ = try store.deleteIdea(ideaID: ideaID)
            Issue.record("a deleted Idea went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_ideas"))
        }
    }

    /// The knowledge boundary holds on an Idea's chips: an episode of a show
    /// the learner muted for the AI is still linked, but the listing does not
    /// name it.
    @Test("A source kept from AI is linked without its title")
    func ideaLinkRespectsTheKnowledgeBoundary() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        var episode = StudioArticle(
            url: "https://pod.example/muted-idea", title: "Kept out of the model's reach",
            sourceType: .podcast, id: "muted-idea"
        )
        episode.domain = "Muted Show"
        try knowledge.saveSource(episode)

        let created = try parseJSON(try store.createIdea(
            title: "Built on something private", notes: nil,
            links: [["kind": "source", "target_id": "muted-idea"]]
        ))
        let ideaID = try #require(created["idea_id"] as? String)

        let named = try parseJSON(try store.listIdeas(includeArchived: true))
        let namedLinks = try #require((named["ideas"] as? [[String: Any]])?.first?["links"] as? [[String: Any]])
        #expect(namedLinks.first?["title"] as? String == "Kept out of the model's reach", "an ordinary source reads as itself")

        try knowledge.setPodcastShowHidden("Muted Show", hidden: true)
        let listed = try parseJSON(try store.listIdeas(includeArchived: true))
        let rows = try #require(listed["ideas"] as? [[String: Any]])
        let links = try #require(rows.first { $0["idea_id"] as? String == ideaID }?["links"] as? [[String: Any]])
        let link = try #require(links.first)
        #expect(link["target_id"] as? String == "muted-idea", "the link is still there")
        #expect(link["title"] == nil, "its title is not")
        #expect(link["withheld_from_ai"] as? Bool == true)
    }

    // MARK: - Directions (docs/directions-design.md)

    /// A direction search over MCP: the brief, the proposals it saves, the
    /// learner's answers, and the brief again, which now leads with them.
    @Test("find_directions briefs a search, propose_directions saves it, update_direction records the answer the next brief reads")
    func directionToolsOverMCP() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_directions_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { cleanup(tmpDir.path) }
        let store = MCPDataStore(
            dbPath: tmpDir.appendingPathComponent("knowledge.db").path,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )
        let knowledge = try store.knowledgeStore()
        for name in ["find_directions", "search_literature", "propose_directions", "list_directions", "update_direction", "delete_direction"] {
            #expect(MCPToolRegistry.shared.tools.contains { $0.name == name }, "\(name) is not registered")
        }
        let proposeDef = try #require(MCPToolRegistry.shared.tools.first { $0.name == "propose_directions" })
        #expect(proposeDef.inputSchema["required"] as? [String] == ["home_id", "directions"])

        try Self.seedReadySource(
            knowledge, id: "jain-2016", url: "https://www.science.org/doi/10.1126/science.aad9642",
            title: "Hypoxia as a therapy for mitochondrial disease", sourceType: .article
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Find methods to target rare mitochondrial diseases", description: "Read it against a phenotyping-first startup.",
            topic: "rare mitochondrial disease therapeutics",
            startAt: Date(), endAt: Date().addingTimeInterval(14 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["jain-2016"], parentNotebookID: nil
        )
        _ = try knowledge.createIdea(title: "Pooled in vivo screening with an MMP readout")

        let first = try parseJSON(try await store.findDirections(homeID: goal.id, focus: "methods to target"))
        let home = try #require(first["home"] as? [String: Any])
        #expect(home["kind"] as? String == "goal")
        #expect(home["focus"] as? String == "methods to target")
        let instructions = try #require(first["standing_instructions"] as? [[String: Any]])
        #expect(instructions.first?["text"] as? String == "Read it against a phenotyping-first startup.")
        let sources = try #require(first["sources"] as? [[String: Any]])
        #expect(sources.map { $0["source_id"] as? String } == ["jain-2016"])
        let ideas = try #require(first["learner_ideas"] as? [[String: Any]])
        #expect(ideas.map { $0["title"] as? String } == ["Pooled in vivo screening with an MMP readout"])
        #expect((first["directions"] as? [[String: Any]])?.isEmpty == true)
        let steps = try #require(first["steps"] as? String)
        #expect(steps.contains("home_id \(goal.id)"))

        do {
            _ = try await store.findDirections(homeID: "nowhere", focus: nil)
            Issue.record("a brief for no home went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("create_idea"))
        }

        let evidence: [[String: Any]] = [[
            "citation": "Jain et al., Science 2016",
            "doi": "10.1126/science.aad9642",
            "url": "https://www.science.org/doi/10.1126/science.aad9642",
            "finding": "Hypoxia prevented disease in Ndufs4 knockout mice.",
        ]]
        do {
            _ = try store.proposeDirections(homeID: goal.id, rawDirections: [[
                "title": "Something", "rationale": "Because", "angle": "hunch", "evidence": evidence,
            ]], sessionID: nil, hostSessionID: nil)
            Issue.record("an unknown angle went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("angle"))
        }
        do {
            _ = try store.proposeDirections(homeID: goal.id, rawDirections: [[
                "title": "Uncited", "rationale": "Because", "angle": "gap", "evidence": [] as [[String: Any]],
            ]], sessionID: nil, hostSessionID: nil)
            Issue.record("a direction citing nothing went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("cites nothing"))
        }

        let proposed = try parseJSON(try store.proposeDirections(homeID: goal.id, rawDirections: [
            [
                "title": "Hypoxia or HIF activation for complex I deficiency",
                "rationale": "Hypoxia rescued the mouse model and a drug now mimics it.",
                "angle": "enabling",
                "evidence": evidence,
                "objection": "Hypoxia worsens some lesions.",
                "next_step": "Map which genotypes were rescued.",
            ],
            [
                "title": "Re-run a failed PMD trial in a phenotype-defined cohort",
                "rationale": "Heterogeneous cohorts diluted signals that subgroups showed.",
                "angle": "revival",
                "evidence": [["citation": "A registry page", "url": "https://clinicaltrials.gov/study/NCT05162768", "finding": "The follow-on trial enrolled one genetic subgroup."]],
            ],
        ], sessionID: nil, hostSessionID: nil))
        #expect(proposed["status"] as? String == "saved")
        let saved = try #require(proposed["saved"] as? [[String: Any]])
        #expect(saved.count == 2)
        let hypoxiaID = try #require(saved.first?["direction_id"] as? String)
        let revivalID = try #require(saved.last?["direction_id"] as? String)

        let again = try parseJSON(try store.proposeDirections(homeID: goal.id, rawDirections: [[
            "title": "hypoxia or HIF activation for complex-I deficiency", "rationale": "Same", "angle": "enabling", "evidence": evidence,
        ]], sessionID: nil, hostSessionID: nil))
        #expect(again["status"] as? String == "nothing_new")
        #expect(again["skipped_as_already_proposed"] as? [String] == ["hypoxia or HIF activation for complex-I deficiency"])

        let listed = try parseJSON(try store.listDirections(homeID: goal.id, statusString: nil))
        let rows = try #require(listed["directions"] as? [[String: Any]])
        #expect(rows.count == 2)
        let hypoxiaRow = try #require(rows.first { $0["direction_id"] as? String == hypoxiaID })
        let rowEvidence = try #require(hypoxiaRow["evidence"] as? [[String: Any]])
        #expect(rowEvidence.first?["in_library"] as? Bool == true, "the library's copy is found by its address")
        #expect(rowEvidence.first?["library_source_id"] as? String == "jain-2016")
        #expect(hypoxiaRow["objection"] as? String == "Hypoxia worsens some lesions.")

        let pursued = try parseJSON(try store.updateDirection(directionID: hypoxiaID, arguments: ["status": "pursued", "reason": "It fits the phenotyping angle"]))
        #expect(pursued["direction_status"] as? String == "pursued")
        _ = try store.updateDirection(directionID: revivalID, arguments: ["status": "set_aside", "reason": "Already knew about it"])
        do {
            _ = try store.updateDirection(directionID: revivalID, arguments: [:])
            Issue.record("an empty change went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("Nothing to change"))
        }

        let second = try parseJSON(try await store.findDirections(homeID: goal.id, focus: nil))
        let answered = try #require(second["directions"] as? [[String: Any]])
        #expect(answered.map { $0["status"] as? String } == ["pursued", "set_aside"], "pursued first, then set aside")
        #expect(answered.map { $0["learner_reason"] as? String } == ["It fits the phenotyping angle", "Already knew about it"])

        let otherGoal = try knowledge.createCompanionGoal(
            title: "Another aim", description: nil, topic: "another",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let elsewhere = try parseJSON(try await store.findDirections(homeID: otherGoal.id, focus: nil))
        let calibration = try #require(elsewhere["answers_elsewhere"] as? [[String: Any]])
        #expect(Set(calibration.compactMap { $0["learner_reason"] as? String }) == ["It fits the phenotyping angle", "Already knew about it"])

        let deleted = try parseJSON(try store.deleteDirection(directionID: revivalID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(try knowledge.loadResearchDirections().map(\.id) == [hypoxiaID])
    }

    /// The drop of sources onto a Goal's row, over MCP (product owner, 2026-09-19:
    /// "allow me to drag sources onto goals ... and via mcp").
    @Test("add_goal_sources puts sources on a Goal and the Notebook it is tagged to, skips repeats, and refuses a Notebook, an unknown source and an empty list")
    func addGoalSourcesOverMCP() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let def = try #require(MCPToolRegistry.shared.tools.first { $0.name == "add_goal_sources" })
        #expect(def.inputSchema["required"] as? [String] == ["goal_id", "source_ids"])

        try Self.seedReadySource(knowledge, id: "src-a", url: "https://example.com/a", title: "A", sourceType: .article)
        try Self.seedReadySource(knowledge, id: "src-b", url: "https://example.com/b", title: "B", sourceType: .article)

        let notebook = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let tagged = try knowledge.createCompanionGoal(
            title: "Understand the method", description: nil, topic: "method",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let standalone = try knowledge.createCompanionGoal(
            title: "Write the article", description: nil, topic: "article",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        let first = try parseJSON(try await store.addGoalSources(goalID: tagged.id, sourceIDs: ["src-a", "src-b"]))
        #expect(first["added"] as? Int == 2)
        #expect(first["skipped"] as? Int == 0)
        #expect(first["source_ids"] as? [String] == ["src-a", "src-b"])
        #expect(first["notebook_id"] as? String == notebook.id)
        #expect(try knowledge.loadLearningGoal(tagged.id)?.approvedSourceIDs == ["src-a", "src-b"])
        #expect(
            try knowledge.loadLearningGoal(notebook.id)?.approvedSourceIDs == ["src-a", "src-b"],
            "a tagged Goal hands its sources on to the Notebook's pool"
        )

        let again = try parseJSON(try await store.addGoalSources(goalID: tagged.id, sourceIDs: ["src-a"]))
        #expect(again["added"] as? Int == 0)
        #expect(again["skipped"] as? Int == 1)
        #expect(again["source_count"] as? Int == 2)

        let alone = try parseJSON(try await store.addGoalSources(goalID: standalone.id, sourceIDs: ["src-b"]))
        #expect(alone["source_count"] as? Int == 1)
        #expect(alone["notebook_id"] == nil, "a standalone Goal names no Notebook")
        let detail = try parseJSON(try store.getGoal(goalID: standalone.id))
        #expect((detail["seeds"] as? [[String: Any]])?.compactMap { $0["source_id"] as? String } == ["src-b"])

        do {
            _ = try await store.addGoalSources(goalID: notebook.id, sourceIDs: ["src-a"])
            Issue.record("a Notebook went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("Notebook"))
        }
        await #expect(throws: MCPError.self) { _ = try await store.addGoalSources(goalID: standalone.id, sourceIDs: ["src-missing"]) }
        await #expect(throws: MCPError.self) { _ = try await store.addGoalSources(goalID: standalone.id, sourceIDs: []) }
        await #expect(throws: MCPError.self) { _ = try await store.addGoalSources(goalID: "nope", sourceIDs: ["src-a"]) }
    }

    @Test("A goal the learner names is a Goal, never an open question: the open-question tool and both chat prompts send \"goal\" to create_learning_goal even without a date")
    func namedGoalIsNeverFiledAsOpenQuestion() throws {
        // The product owner (2026-09-20): "can you set up a goal where I want to
        // understand these cross-modality predictions" landed in a Notebook's
        // open questions because create_learning_goal needs an end_date the
        // learner had not given. The missing date changes nothing about what
        // the thing is; the assistant proposes a deadline instead.
        let openQuestion = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_open_question" })
        #expect(openQuestion.description.contains("NOT a Goal"))
        #expect(openQuestion.description.contains("use create_learning_goal instead"))
        #expect(openQuestion.description.contains("propose one and confirm it rather than filing the goal here"))
        #expect(Prompts.mcpServerInstructions.contains("A goal voiced without a date is still a Goal"))
        #expect(Prompts.mcpServerInstructions.contains("Never file it as an open question (create_open_question)"))
        #expect(Prompts.appAssistant.contains("or ask for a goal by name"))
        #expect(Prompts.appAssistant.contains("A missing date never changes what the thing is"))
    }

    @Test("A Goal is for a Doc or Site over MCP: create_learning_goal takes artifact_id, rows answer artifact, update_learning_goal unlinks, an unknown id is refused")
    func goalArtifactOverMCP() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let create = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_learning_goal" })
        #expect((create.inputSchema["properties"] as? [String: Any])?["artifact_id"] != nil)
        let update = try #require(MCPToolRegistry.shared.tools.first { $0.name == "update_learning_goal" })
        #expect((update.inputSchema["properties"] as? [String: Any])?["artifact_id"] != nil)

        let created = try parseJSON(try await store.createArtifact(
            title: "Rare mitochondrial diseases", homeNotebookID: nil, notebookIDs: [], markdown: "# Rare mitochondrial diseases"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        let endDate = formatter.string(from: Date().addingTimeInterval(7 * 86_400))

        let brief = try await store.createCompanionLearningGoal(
            title: "Make a site of the rare mitochondrial diseases", topic: nil,
            endDateString: endDate, startDateString: nil, sourceIDs: [],
            dailyTarget: nil, discover: false, notebookID: nil, artifactID: docID
        )
        #expect(brief.contains("For “Rare mitochondrial diseases”; the Goal's row opens it."))
        #expect(!brief.contains("Created timebound Goal \(docID)"))

        let listed = try parseJSON(try store.listNotebookGoals(notebookID: nil))
        let rows = try #require(listed["goals"] as? [[String: Any]])
        let row = try #require(rows.first)
        let goalID = try #require(row["id"] as? String)
        let artifact = try #require(row["artifact"] as? [String: Any])
        #expect(artifact["id"] as? String == docID)
        #expect(artifact["title"] as? String == "Rare mitochondrial diseases")
        #expect(artifact["kind"] as? String == "doc")
        #expect(try knowledge.loadLearningGoal(goalID)?.linkedArtifactID == docID)

        let detail = try parseJSON(try store.getGoal(goalID: goalID))
        #expect((detail["artifact"] as? [String: Any])?["id"] as? String == docID)

        do {
            _ = try await store.updateLearningGoal(
                goalID: goalID, title: nil, description: nil, topic: nil, endDateString: nil,
                dailyTarget: nil, discover: nil, notebookID: nil, statusString: nil, artifactID: "nope"
            )
            Issue.record("an unknown artifact id went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("No Doc, Site or animation"))
        }
        #expect(try knowledge.loadLearningGoal(goalID)?.linkedArtifactID == docID, "a refusal changes nothing")

        let unlinked = try await store.updateLearningGoal(
            goalID: goalID, title: nil, description: nil, topic: nil, endDateString: nil,
            dailyTarget: nil, discover: nil, notebookID: nil, statusString: nil, artifactID: ""
        )
        #expect(unlinked.contains("No longer for any Doc, Site or animation"))
        let cleared = try parseJSON(try store.getGoal(goalID: goalID))
        #expect(cleared["artifact"] is NSNull)
        #expect(try knowledge.loadLearningGoal(goalID)?.artifactID == "", "an unlink is an explicit clear")

        // A Notebook never answers the question: it is not for one artifact.
        _ = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let notebooks = try parseJSON(try store.listCompanionLearningGoals(topLevelOnly: true))
        let notebookRow = try #require((notebooks["goals"] as? [[String: Any]])?.first)
        #expect(notebookRow["artifact"] == nil)
    }

    @Test("A Goal stands on its own over MCP: no notebook_id to create it, list_goals has it, list_notebooks does not, and a tag can come and go")
    func standaloneGoalOverMCP() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let create = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_learning_goal" })
        #expect(create.inputSchema["required"] as? [String] == ["title", "end_date"])

        let notebook = try knowledge.createCompanionGoal(
            title: "OxPhos", topic: "oxphos", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        let endDate = formatter.string(from: try #require(Calendar.current.date(byAdding: .day, value: 5, to: Date())))

        let created = try await store.createCompanionLearningGoal(
            title: "Understand Zara's thesis work", topic: nil, endDateString: endDate, startDateString: nil,
            sourceIDs: [], dailyTarget: nil, discover: false, notebookID: nil
        )
        #expect(!created.contains("Belongs to Notebook"), "no Notebook was invented to hold it")
        let goal = try #require(try knowledge.loadLearningGoals().first { $0.title == "Understand Zara's thesis work" })
        #expect(goal.isGoal && goal.isStandaloneGoal && !goal.isNotebook)

        func ids(_ json: String) throws -> [String] {
            ((try parseJSON(json))["goals"] as? [[String: Any]])?.compactMap { $0["id"] as? String ?? $0["goal_id"] as? String } ?? []
        }
        #expect(try ids(try store.listNotebookGoals(notebookID: nil)) == [goal.id], "list_goals lists a Goal that names no Notebook")
        #expect(try ids(try store.listCompanionLearningGoals(topLevelOnly: true)) == [notebook.id], "list_notebooks never lists a Goal")
        #expect(try store.listNotebookGoals(notebookID: notebook.id).contains("has no Goals yet"))

        // get_goal answers for it, and a Notebook is refused by the Goal tools.
        let detail = try parseJSON(try store.getGoal(goalID: goal.id))
        #expect(detail["notebook_id"] == nil)
        #expect(throws: MCPError.self) { _ = try store.getGoal(goalID: notebook.id) }

        // Tag it to a Notebook, then untag it with "".
        _ = try await store.updateLearningGoal(
            goalID: goal.id, title: nil, description: nil, topic: nil, endDateString: nil, dailyTarget: nil, discover: nil,
            notebookID: notebook.id, statusString: nil
        )
        #expect(try knowledge.loadLearningGoal(goal.id)?.parentNotebookID == notebook.id)
        #expect(try ids(try store.listNotebookGoals(notebookID: notebook.id)) == [goal.id])
        _ = try await store.updateLearningGoal(
            goalID: goal.id, title: nil, description: nil, topic: nil, endDateString: nil, dailyTarget: nil, discover: nil,
            notebookID: "", statusString: nil
        )
        let untagged = try #require(try knowledge.loadLearningGoal(goal.id))
        #expect(untagged.parentNotebookID == nil && untagged.isStandaloneGoal)
        #expect(untagged.endAt == goal.endAt, "untagging keeps the deadline")
        #expect(try ids(try store.listCompanionLearningGoals(topLevelOnly: true)) == [notebook.id])
    }

    @Test("list_goals counts the days a Goal has left the way the Goals tab does: 0 on the day it falls due, never one more")
    func goalDaysRemainingMatchTheRail() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()

        func goal(endingIn days: Int, _ title: String) async throws -> LearningGoalRecord {
            let end = formatter.string(from: try #require(calendar.date(byAdding: .day, value: days, to: now)))
            // A Goal must end after it starts, so one falling due today began yesterday.
            let start = formatter.string(from: try #require(calendar.date(byAdding: .day, value: -1, to: now)))
            _ = try await store.createCompanionLearningGoal(
                title: title, topic: nil, endDateString: end, startDateString: start,
                sourceIDs: [], dailyTarget: nil, discover: false, notebookID: nil
            )
            return try #require(try knowledge.loadLearningGoals().first { $0.title == title })
        }
        let dueToday = try await goal(endingIn: 0, "Due today")
        let inFive = try await goal(endingIn: 5, "In five days")

        let listed = (try parseJSON(try store.listNotebookGoals(notebookID: nil))["goals"] as? [[String: Any]]) ?? []
        func remaining(_ id: String) -> Int? {
            listed.first { ($0["id"] as? String ?? $0["goal_id"] as? String) == id }?["days_remaining"] as? Int
        }
        // Until 2026-09-20 the handler added one, so the rail's "due today" listed as a day left.
        #expect(remaining(dueToday.id) == 0)
        #expect(remaining(dueToday.id) == dueToday.daysRemaining(asOf: now, calendar: calendar))
        #expect(remaining(inFive.id) == 5)
        #expect(remaining(inFive.id) == inFive.daysRemaining(asOf: now, calendar: calendar))

        // get_goal reads the same figure, and the in-app quiz card plan too.
        let detail = try parseJSON(try store.getGoal(goalID: inFive.id))
        #expect(detail["days_remaining"] as? Int == 5)
        #expect(CompanionCardPlan(goal: dueToday).daysRemaining == 0)
        #expect(CompanionCardPlan(goal: inFive).daysRemaining == 5)
    }

    @Test("Goals reorder over MCP: reorder_goals places the listed first, the rest follow as they read, list_goals reads the order, an empty list is deadline order again, and a Notebook or a finished Goal is refused")
    func reorderGoalsOverMCP() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "reorder_goals" })
        #expect((tool.inputSchema["required"] as? [String]) == ["goal_ids"])

        let now = Date()
        func goal(_ title: String, days: Double) throws -> LearningGoalRecord {
            try knowledge.createCompanionGoal(
                title: title, topic: title, startAt: now, endAt: now.addingTimeInterval(days * 86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
            )
        }
        let soon = try goal("Due soon", days: 1)
        let week = try goal("Due in a week", days: 7)
        let month = try goal("Due in a month", days: 30)
        let done = try goal("Done already", days: 3)
        try knowledge.setLearningGoalStatus(goalID: done.id, status: .done)
        let notebook = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        func listedIDs() throws -> [String] {
            let listed = try parseJSON(try store.listNotebookGoals(notebookID: nil))
            return (listed["goals"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        #expect(try listedIDs() == [soon.id, week.id, month.id], "before any placement the list reads by deadline")

        // A subset: the one named goes first, the other two keep their order.
        let placed = try parseJSON(try store.reorderGoals(goalIDs: [month.id]))
        #expect((placed["goals"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [month.id, soon.id, week.id])
        #expect(try listedIDs() == [month.id, soon.id, week.id])
        #expect(try knowledge.loadLearningGoal(month.id)?.sortOrder == 0)
        #expect(try knowledge.loadLearningGoal(week.id)?.sortOrder == 2)

        // Back to deadline order.
        let cleared = try parseJSON(try store.reorderGoals(goalIDs: []))
        #expect((cleared["note"] as? String)?.contains("by deadline") == true)
        #expect(try listedIDs() == [soon.id, week.id, month.id])
        #expect(try knowledge.loadLearningGoal(month.id)?.sortOrder == nil)

        for refused in [notebook.id, done.id, "nope"] {
            do {
                _ = try store.reorderGoals(goalIDs: [refused])
                Issue.record("\(refused) was placed")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("Use list_goals"))
            }
        }
        #expect(try listedIDs() == [soon.id, week.id, month.id], "a refusal changes nothing")
    }

    @Test("Notebook-scoped tools require an explicit notebook id")
    func notebookScopedToolsRequireExplicitNotebookID() throws {
        let names = [
            "update_notebook",
            "get_notebook",
            "add_notebook_sources",
            "list_notebook_sources",
            "reorder_notebook_sources",
            "set_notebook_source_selection",
            "get_notebook_context",
            "list_notebook_files",
            "read_notebook_markdown_file",
            "write_notebook_markdown_file",
            "update_notebook_notes",
            "append_notebook_notes",
            "split_notebook",
            "list_open_questions",
            "create_open_question",
            "update_open_question",
        ]

        for name in names {
            let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == name })
            let required = try #require(tool.inputSchema["required"] as? [String])
            #expect(required.contains("notebook_id"), "Expected \(name) to require notebook_id")
        }
    }

    @Test("Each window's notebook is discoverable, frontmost first, but never an implicit tool target")
    func windowNotebooksAreNotImplicitToolTargets() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "front-source", title: "Front reading", content: "Front text.")
        try insertSource(dbPath: dbPath, id: "back-source", title: "Back reading", content: "Back text.")
        let knowledge = try store.knowledgeStore()
        func notebook(_ title: String, seeds: [String]) throws -> LearningGoalRecord {
            try knowledge.createCompanionGoal(
                title: title,
                topic: title,
                startAt: Date(),
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: seeds
            )
        }
        let front = try notebook("Open in front", seeds: ["front-source"])
        let back = try notebook("Open behind", seeds: ["back-source"])

        // The registry hands these over frontmost first.
        let windows = MCPAppWindows.ordered(notebookIDs: [back.id, nil, front.id], frontmost: 2)
        #expect(windows.map(\.notebookID) == [front.id, back.id, nil])
        #expect(windows.map(\.isFrontmost) == [true, false, false])

        let context = try store.getAppContext(windows: windows)
        let lines = context.components(separatedBy: "\n")
        #expect(lines.first == "3 ForeverLM windows are open, frontmost first. What they hold is never an implicit MCP default: pass notebook_id explicitly to Notebook tools.")
        #expect(lines.contains("- Frontmost window: Notebook 'Open in front' (notebook_id: \(front.id), 1 source)"))
        #expect(lines.contains("- Window: Notebook 'Open behind' (notebook_id: \(back.id), 1 source)"))
        #expect(lines.contains("- Window: no notebook open"))
        // The frontmost window's notebook's sources follow; the others' do not.
        #expect(context.contains("Front text."))
        #expect(!context.contains("Back text."))
        #expect(!context.contains("legacy"))

        #expect(try store.getAppContext(windows: []).hasPrefix("No ForeverLM window is open."))
        let homeOnly = try store.getAppContext(windows: MCPAppWindows.ordered(notebookIDs: [nil], frontmost: 0))
        #expect(homeOnly.contains("- Frontmost window: no notebook open"))

        // No tool falls back to a window's notebook.
        #expect(throws: MCPError.self) {
            _ = try store.listNotebookSources(notebookID: nil)
        }
        #expect(try store.listNotebookSources(notebookID: front.id).contains("Front reading"))
    }

    @Test("open question tools create, list, and update notebook gaps")
    func openQuestionToolsRoundTrip() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src-1", title: "Paper A", content: "Mechanism details.")

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "Immunology",
            topic: "B cells",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1"]
        )
        let created = try parseJSON(try store.createOpenQuestion(
            notebookID: goal.id,
            summary: "How do B cells present antigen?",
            sourceID: "src-1",
            severity: 0.8,
            status: nil
        ))
        let question = try #require(created["open_question"] as? [String: Any])
        let questionID = try #require(question["question_id"] as? String)
        #expect(question["summary"] as? String == "How do B cells present antigen?")
        #expect(question["status"] as? String == "open")

        let listed = try parseJSON(try store.listOpenQuestions(notebookID: goal.id, includeResolved: false, status: nil))
        let questions = try #require(listed["open_questions"] as? [[String: Any]])
        #expect(questions.count == 1)
        #expect(questions.first?["question_id"] as? String == questionID)

        let updated = try parseJSON(try store.updateOpenQuestion(
            notebookID: goal.id,
            questionID: questionID,
            summary: "How do B cells present antigen to T cells?",
            sourceID: nil,
            severity: nil,
            status: "improving",
            clearSourceID: false
        ))
        let patched = try #require(updated["open_question"] as? [String: Any])
        #expect(patched["status"] as? String == "improving")
        #expect(patched["summary"] as? String == "How do B cells present antigen to T cells?")
    }

    @Test("list notebook sources includes derived understanding state")
    func listNotebookSourcesIncludesUnderstandingState() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src-new", title: "Fresh", content: "Unread.")
        try insertSource(dbPath: dbPath, id: "src-read", title: "Started", content: "In progress.")

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "States",
            topic: "states",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-new", "src-read"]
        )
        var items = try #require(try ks.loadLearningGoal(goal.id)?.items)
        if let index = items.firstIndex(where: { $0.sourceID == "src-read" }) {
            items[index].lastQuizzedAt = Date()
            items[index].quizCount = 1
            items[index].lastScore = 0.4
            var record = try #require(try ks.loadLearningGoal(goal.id))
            record.items = items
            try ks.saveLearningGoalRecord(record)
        }

        let payload = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
        let sources = try #require(payload["sources"] as? [[String: Any]])
        let fresh = try #require(sources.first { ($0["id"] as? String) == "src-new" })
        let started = try #require(sources.first { ($0["id"] as? String) == "src-read" })
        #expect(fresh["understanding_state"] as? String == "to-read")
        #expect(started["understanding_state"] as? String == "reading")
        #expect(started["last_score"] as? Double == 0.4)
        // Each source carries the link a reply shows instead of its id.
        #expect(fresh["link"] as? String == "[Fresh](foreverlm://source/src-new)")
    }
}

#endif
