// MCPDataStoreTests: Notebook chat checkboxes, context Notebooks, settings tools, animations and Spaces of pages.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    // MARK: Notebook chat checkboxes

    /// Runs `body` on a notebook state of its own (`NotebookStateStore.override`),
    /// never the learner's, and hands it the box to seed and assert on.
    private func withNotebookSelectionState(_ body: (NotebookStateStore.Box) async throws -> Void) async throws {
        let box = NotebookStateStore.Box()
        try await NotebookStateStore.$override.withValue(box) { try await body(box) }
    }

    /// A Notebook holding three readable sources, in study order.
    private func makeSelectionNotebook(store: MCPDataStore, tmpPath: String) throws -> LearningGoalRecord {
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        for id in ["src-1", "src-2", "src-3"] {
            try insertSource(dbPath: dbPath, id: id, title: "Paper \(id)", content: "Text of \(id).")
        }
        return try store.knowledgeStore().createCompanionGoal(
            title: "Selection",
            topic: "selection",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1", "src-2", "src-3"]
        )
    }

    @Test("set_notebook_source_selection ticks and unticks a Notebook's sources for its chats, never its membership")
    func notebookSourceSelectionSetsInChat() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)

        try await withNotebookSelectionState { box in
            let excluded = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-2"], mode: "exclude")
            )
            #expect(excluded["updated"] as? Bool == true)
            #expect(excluded["in_chat_count"] as? Int == 2)
            #expect(excluded["in_chat_source_ids"] as? [String] == ["src-1", "src-3"])
            #expect(excluded["excluded_source_ids"] as? [String] == ["src-2"])
            #expect(box.snapshot.excluded[goal.id] == Set(["src-2"]))

            let listed = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
            #expect(listed["source_count"] as? Int == 3)
            #expect(listed["in_chat_count"] as? Int == 2)
            let sources = try #require(listed["sources"] as? [[String: Any]])
            let inChat = Dictionary(uniqueKeysWithValues: sources.compactMap { source -> (String, Bool)? in
                guard let id = source["id"] as? String, let flag = source["in_chat"] as? Bool else { return nil }
                return (id, flag)
            })
            #expect(inChat == ["src-1": true, "src-2": false, "src-3": true])
            #expect(try store.notebookChatSourceIDs(goal: goal, store: store.knowledgeStore()) == ["src-1", "src-3"])

            let only = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-3"], mode: "only")
            )
            #expect(only["in_chat_source_ids"] as? [String] == ["src-3"])
            #expect(box.snapshot.excluded[goal.id] == Set(["src-1", "src-2"]))

            let included = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "include")
            )
            #expect(included["in_chat_source_ids"] as? [String] == ["src-1", "src-3"])

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], mode: "none")
            #expect(box.snapshot.excluded[goal.id] == Set(["src-1", "src-2", "src-3"]))

            let all = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], mode: "all")
            )
            #expect(all["in_chat_count"] as? Int == 3)
            #expect(box.snapshot.excluded[goal.id] == nil, "everything ticked is the default and has no row")

            let reloaded = try #require(try store.knowledgeStore().loadLearningGoal(goal.id))
            #expect(reloaded.approvedSourceIDs == ["src-1", "src-2", "src-3"], "membership is untouched")
        }
    }

    @Test("set_notebook_source_selection refuses a source outside the Notebook, a missing source_ids, and an unknown mode, writing nothing")
    func notebookSourceSelectionRefusals() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)

        try await withNotebookSelectionState { box in
            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1", "elsewhere"], mode: "exclude")
                Issue.record("a source outside the Notebook was unticked")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("list_notebook_sources"))
            }
            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], mode: "exclude")
                Issue.record("exclude without source_ids was accepted")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("source_ids is required"))
            }
            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "untick")
                Issue.record("an unknown mode was accepted")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("mode must be"))
            }
            #expect(box.snapshot.excluded[goal.id] == nil, "a refusal writes nothing")
        }
    }

    @Test("deleting a Notebook drops its chat selection row")
    func deleteNotebookForgetsChatSelection() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)

        try await withNotebookSelectionState { box in
            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "exclude")
            #expect(box.snapshot.excluded[goal.id] == Set(["src-1"]))

            _ = try store.deleteNotebook(notebookID: goal.id)

            #expect(box.snapshot.excluded[goal.id] == nil)
        }
    }

    /// A context notebook holding src-3 (the selection Notebook's too), src-4
    /// and src-5, linked to `goal` when `linked` is true.
    private func makeContextNotebook(
        store: MCPDataStore,
        tmpPath: String,
        for goal: LearningGoalRecord,
        linked: Bool = true
    ) throws -> LearningGoalRecord {
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        for id in ["src-4", "src-5"] {
            try insertSource(dbPath: dbPath, id: id, title: "Paper \(id)", content: "Text of \(id).")
        }
        let context = try store.knowledgeStore().createCompanionGoal(
            title: "Context",
            topic: "context",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-3", "src-4", "src-5"]
        )
        if linked {
            try store.knowledgeStore().setRelatedNotebooks(notebookID: goal.id, relatedNotebookIDs: [context.id])
        }
        return context
    }

    @Test("list_notebook_sources lists a context notebook's sources after the Notebook's own, read by its chats only once put in")
    func listNotebookSourcesMarksContextNotebooks() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let context = try makeContextNotebook(store: store, tmpPath: tmpPath, for: goal)

        try await withNotebookSelectionState { box in
            var listed = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
            var sources = try #require(listed["sources"] as? [[String: Any]])
            #expect(sources.compactMap { $0["id"] as? String } == ["src-1", "src-2", "src-3", "src-4", "src-5"],
                    "its own, then the context notebook's it does not hold")
            #expect(sources.compactMap { $0["via_context_notebook_id"] as? String } == [context.id, context.id])
            #expect(sources[3]["via_context_notebook_title"] as? String == "Context")
            #expect(sources.compactMap { $0["in_chat"] as? Bool } == [true, true, true, false, false], "linked alone reads nothing")
            #expect(listed["in_chat_count"] as? Int == 3)
            var notebooks = try #require(listed["context_notebooks"] as? [[String: Any]])
            #expect(notebooks.map { $0["notebook_id"] as? String } == [context.id])
            #expect(notebooks.first?["in_chat"] as? Bool == false)
            let linkedGoal = try #require(try store.knowledgeStore().loadLearningGoal(goal.id))
            #expect(try store.notebookChatSourceIDs(goal: linkedGoal, store: store.knowledgeStore()) == ["src-1", "src-2", "src-3"])

            let putIn = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include"
            ))
            #expect(putIn["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4", "src-5"])
            #expect(box.snapshot.contextNotebooks[goal.id] == Set([context.id]))

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-5"], mode: "exclude")
            listed = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
            sources = try #require(listed["sources"] as? [[String: Any]])
            #expect(sources.compactMap { $0["in_chat"] as? Bool } == [true, true, true, true, false])
            notebooks = try #require(listed["context_notebooks"] as? [[String: Any]])
            #expect(notebooks.first?["in_chat"] as? Bool == true)
            #expect(notebooks.first?["in_chat_count"] as? Int == 2)

            let out = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "exclude"
            ))
            #expect(out["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3"])
            #expect(box.snapshot.contextNotebooks[goal.id] == nil)
            #expect(box.snapshot.excluded[goal.id] == Set(["src-5"]),
                    "its sources' boxes are kept for when it comes back")

            // Put back in, it comes as it was left: src-5 still unticked.
            let back = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include"
            ))
            #expect(back["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4"])
            #expect(box.snapshot.excluded[goal.id] == Set(["src-5"]))
            // Included again while it is in, every source of it is ticked, as its box does.
            let whole = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include"
            ))
            #expect(whole["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4", "src-5"])
            #expect(box.snapshot.excluded[goal.id] == nil)
            _ = try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "exclude"
            )

            let one = try parseJSON(try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-4"], mode: "include"))
            #expect(one["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4"],
                    "ticking a source of a context notebook out of the chats puts it in with that source alone")
            #expect(box.snapshot.contextNotebooks[goal.id] == Set([context.id]))

            let only = try parseJSON(try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "only"))
            #expect(only["in_chat_source_ids"] as? [String] == ["src-1"])
            #expect(box.snapshot.contextNotebooks[goal.id] == nil, "only takes every context notebook it does not name out")

            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], contextNotebookIDs: ["not-linked"], mode: "include")
                Issue.record("a notebook the Notebook does not link was put in")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("not a context notebook"))
            }
        }
    }

    @Test("get_notebook_context reads a context notebook's sources and notes only once it is in the Notebook's chats, and says what it leaves out")
    func getNotebookContextFollowsContextNotebooks() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let context = try makeContextNotebook(store: store, tmpPath: tmpPath, for: goal)

        try await withNotebookSelectionState { _ in
            let before = try await store.getNotebookContext(
                notebookID: goal.id, maxSourceChars: nil, includeEmergentState: true, includeSourceContent: true
            )
            #expect(before.contains("Text of src-3."))
            #expect(!before.contains("Text of src-4."))
            #expect(!before.contains("# Context notebook"))
            #expect(before.contains("1 context notebook out of its chats"))

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include")
            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-2"], mode: "exclude")
            let after = try await store.getNotebookContext(
                notebookID: goal.id, maxSourceChars: nil, includeEmergentState: true, includeSourceContent: true
            )
            #expect(after.contains("Text of src-4.") && after.contains("Text of src-5."))
            #expect(after.contains("# Context notebook"))
            #expect(!after.contains("Text of src-2."), "an unticked source is left out")
            #expect(after.contains("1 source the learner unticked"))
            #expect(!after.contains("out of its chats"))
        }
    }

    @Test("get notebook context includes emergent state and source content")
    func getNotebookContextIncludesEmergentState() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src-1", title: "Core paper", content: "Important mechanism.")

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "Mechanisms",
            topic: "mechanisms",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1"]
        )
        let briefDirectory = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("Projects/\(goal.id)/Requirements", isDirectory: true)
        try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
        let briefURL = briefDirectory.appendingPathComponent("challenge description.pdf")
        let briefRequirement = "The final analysis must distinguish correlation from the rate-limiting mechanism."
        try makeTestPDF(
            at: briefURL,
            text: """
            Notebook challenge description. Use the supplied observations to compare the candidate mechanisms,
            document assumptions, test each explanation against held-out evidence, and report uncertainty clearly.
            \(briefRequirement) The submission should remain reproducible and concise for a technical reader.
            """
        )
        let briefValues = try briefURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let briefDate = briefValues.contentModificationDate ?? Date()
        let referencesDirectory = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("Projects/\(goal.id)/Papers I care about", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)
        let referenceURL = referencesDirectory.appendingPathComponent("supporting paper.pdf")
        let referenceEvidence = "The reference paper identifies a mechanistic bottleneck in the final reaction step."
        try makeTestPDF(at: referenceURL, text: referenceEvidence)
        let referenceValues = try referenceURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let referenceDate = referenceValues.contentModificationDate ?? Date()
        let dataDirectory = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("Projects/\(goal.id)/Screening run", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let dataURL = dataDirectory.appendingPathComponent("observations.tsv")
        let dataEvidence = "candidate_17\t0.942"
        try Data("candidate\tscore\n\(dataEvidence)\n".utf8).write(to: dataURL)
        let dataValues = try dataURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let dataDate = dataValues.contentModificationDate ?? Date()
        try ks.replaceNotebookFiles(
            notebookID: goal.id,
            with: [
                NotebookFileRecord(
                    id: "brief-file",
                    notebookID: goal.id,
                    relativePath: "Projects/\(goal.id)/Requirements/challenge description.pdf",
                    name: "challenge description.pdf",
                    contentType: "com.adobe.pdf",
                    sizeBytes: Int64(briefValues.fileSize ?? 0),
                    modifiedAt: briefDate,
                    createdAt: briefValues.creationDate ?? briefDate
                ),
                NotebookFileRecord(
                    id: "reference-file",
                    notebookID: goal.id,
                    relativePath: "Projects/\(goal.id)/Papers I care about/supporting paper.pdf",
                    name: "supporting paper.pdf",
                    contentType: "com.adobe.pdf",
                    sizeBytes: Int64(referenceValues.fileSize ?? 0),
                    modifiedAt: referenceDate,
                    createdAt: referenceValues.creationDate ?? referenceDate
                ),
                NotebookFileRecord(
                    id: "data-file",
                    notebookID: goal.id,
                    relativePath: "Projects/\(goal.id)/Screening run/observations.tsv",
                    name: "observations.tsv",
                    contentType: "public.tab-separated-values-text",
                    sizeBytes: Int64(dataValues.fileSize ?? 0),
                    modifiedAt: dataDate,
                    createdAt: dataValues.creationDate ?? dataDate
                ),
            ]
        )
        try ks.setLearningGoalNotes(goalID: goal.id, notes: "Synthesis so far.")
        _ = try store.createOpenQuestion(
            notebookID: goal.id,
            summary: "What is the rate-limiting step?",
            sourceID: "src-1",
            severity: nil,
            status: nil
        )
        let context = try await store.getNotebookContext(
            notebookID: goal.id,
            maxSourceChars: 4_000,
            includeEmergentState: true,
            includeSourceContent: true
        )
        #expect(context.contains("## Synthesis notes"))
        #expect(context.contains("Synthesis so far."))
        #expect(context.contains("## Open questions"))
        #expect(context.contains("What is the rate-limiting step?"))
        #expect(context.contains("## Source understanding"))
        #expect(context.contains("Core paper"))
        #expect(context.contains("Important mechanism."))
        // Sources are shown as links and the Notebook by its title, never an
        // id written beside a name (Prompts.hiddenIDs).
        #expect(context.contains("- source: [Core paper](foreverlm://source/src-1)"))
        #expect(context.contains("- [Core paper](foreverlm://source/src-1): "))
        #expect(context.contains("# Notebook 'Mechanisms'\n"))
        #expect(!context.contains("(id: \(goal.id)"))
        #expect(!context.contains("(src-1)"))
        #expect(context.contains("## Notebook files"))
        #expect(context.contains("### Requirements/challenge description.pdf"))
        #expect(context.contains("### Papers I care about/supporting paper.pdf"))
        #expect(context.contains("### Screening run/observations.tsv"))
        #expect(context.contains("challenge description.pdf"))
        let normalizedContext = context.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(normalizedContext.contains(briefRequirement))
        #expect(normalizedContext.contains(referenceEvidence))
        #expect(context.contains(dataEvidence))

        let stateOnly = try await store.getNotebookContext(
            notebookID: goal.id,
            maxSourceChars: nil,
            includeEmergentState: true,
            includeSourceContent: false
        )
        #expect(stateOnly.contains("Synthesis so far."))
        let normalizedStateOnly = stateOnly.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(normalizedStateOnly.contains(briefRequirement))
        #expect(normalizedStateOnly.contains(referenceEvidence))
        #expect(stateOnly.contains(dataEvidence))
        #expect(!stateOnly.contains("Important mechanism."))
    }

    @Test("schedule tool is exposed in MCP registry")
    func scheduleToolIsRegistered() {
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "get_schedule" })
    }

    @Test("schedule assignment tool is exposed in MCP registry")
    func scheduleAssignmentToolIsRegistered() {
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "assign_sources_to_day" })
    }

    @Test("schedule control tools are exposed in MCP registry")
    func scheduleControlToolsAreRegistered() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("unschedule_sources"))
        #expect(toolNames.contains("clear_schedule_day"))
        #expect(toolNames.contains("mark_schedule_day_done"))
        #expect(toolNames.contains("set_source_completion"))
        #expect(toolNames.contains("forget_source_activity"))
    }

    @Test("get_source_settings and set_source_settings are Settings › Sources")
    func sourceSettingsToolsDriveTheSourcesPane() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let defaults = UserDefaults.standard
        let hiddenKey = "studio.hiddenTabs"
        let knowledgeKey = StudioSidebarTab.knowledgeExclusionPreferenceKey
        let autoUnpinnedKey = StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey
        let keys = [hiddenKey, knowledgeKey, autoUnpinnedKey, "studio.tabOrder"]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        // A library as Studio leaves a new one: the integration tabs off the
        // bar by Studio's own hand, everything in knowledge.
        defaults.set(["Meetings", "X"], forKey: hiddenKey)
        defaults.set(["Meetings", "X"], forKey: autoUnpinnedKey)

        func rows(_ json: String) throws -> [String: [String: Any]] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let families = try #require(object["families"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: families.map { ($0["family"] as! String, $0) })
        }

        // Read: one row per family, both switches as the pane shows them.
        let initial = try rows(try store.getSourceSettings())
        #expect(initial.count == StudioSidebarTab.allCases.count)
        #expect(initial["podcasts"]?["include_in_search_and_ai"] as? Bool == true)
        #expect(initial["podcasts"]?["pinned"] as? Bool == true)
        #expect(initial["meetings"]?["pinned"] as? Bool == false)
        #expect(initial["youtube"]?["label"] as? String == "YouTube")

        // Search & AI off for podcasts: the knowledge boundary every library
        // tool draws now excludes a podcast episode, and nothing else moved.
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(kstore, id: "ep-1", url: "https://pod.example/ep1", title: "Episode 1", sourceType: .podcast)
        try Self.seedReadySource(kstore, id: "web-1", url: "https://example.org/mito", title: "Mitochondria explained", sourceType: .article)
        let excluded = try await store.setSourceSettings(family: "podcasts", includeInSearchAndAI: false, pinned: nil)
        let excludedJSON = try #require(try JSONSerialization.jsonObject(with: Data(excluded.utf8)) as? [String: Any])
        #expect(excludedJSON["updated"] as? Bool == true)
        #expect(excludedJSON["include_in_search_and_ai"] as? Bool == false)
        #expect(excludedJSON["pinned"] as? Bool == true)
        #expect(defaults.stringArray(forKey: knowledgeKey) == ["Podcasts"])
        let boundary = try kstore.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        #expect(boundary.contains("ep-1"))
        #expect(!boundary.contains("web-1"))
        #expect(defaults.stringArray(forKey: hiddenKey) == ["Meetings", "X"])

        // Back on, by the label the pane shows rather than the id.
        _ = try await store.setSourceSettings(family: "Podcasts", includeInSearchAndAI: true, pinned: nil)
        #expect(defaults.stringArray(forKey: knowledgeKey) == [])
        #expect(try kstore.knowledgeSearchExcludedSourceIDs(includeArchived: true).isEmpty)

        // Pin Meetings back: the tab leaves the hidden set, and Studio's record
        // that the unpin was its own is dropped, exactly as showTab does.
        _ = try await store.setSourceSettings(family: "meetings", includeInSearchAndAI: nil, pinned: true)
        #expect(defaults.stringArray(forKey: hiddenKey) == ["X"])
        #expect(defaults.stringArray(forKey: autoUnpinnedKey) == ["X"])

        // Unpin YouTube, by its pre-rename stored name.
        _ = try await store.setSourceSettings(family: "Videos", includeInSearchAndAI: nil, pinned: false)
        #expect(defaults.stringArray(forKey: hiddenKey) == ["X", "YouTube"])

        // A no-op write reports nothing changed and writes nothing.
        let same = try await store.setSourceSettings(family: "youtube", includeInSearchAndAI: nil, pinned: false)
        let sameJSON = try #require(try JSONSerialization.jsonObject(with: Data(same.utf8)) as? [String: Any])
        #expect(sameJSON["updated"] as? Bool == false)

        // The tab bar keeps at least one pinned family.
        defaults.set(StudioSidebarTab.allCases.filter { $0 != .papers }.map(\.rawValue), forKey: hiddenKey)
        await #expect(throws: MCPError.self) {
            _ = try await store.setSourceSettings(family: "papers", includeInSearchAndAI: nil, pinned: false)
        }
        #expect(try rows(try store.getSourceSettings())["papers"]?["can_unpin"] as? Bool == false)

        // Unknown family, and a call that changes nothing, are refused.
        await #expect(throws: MCPError.self) {
            _ = try await store.setSourceSettings(family: "slack", includeInSearchAndAI: false, pinned: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setSourceSettings(family: "papers", includeInSearchAndAI: nil, pinned: nil)
        }

        // Registered, and the schema's family enum is the reader's ids.
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        #expect(tools.contains { $0.name == "get_source_settings" })
        let setter = try #require(tools.first { $0.name == "set_source_settings" })
        let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
        let family = try #require(properties["family"] as? [String: Any])
        #expect(family["enum"] as? [String] == MCPDataStore.sourceFamilyIDs)
        #expect(MCPDataStore.sourceFamilyIDs == ["articles", "papers", "books", "meetings", "podcasts", "youtube", "x"])
    }

    @Test("The Zoom recordings only Zoom can convert are the Meetings tab's rows over MCP: listed with this Mac's folders, resolved only for a folder the scan itself listed")
    func unconvertedZoomRecordingsOverMCP() async throws {
        // The product owner (2026-09-20): a background pass opening a raw `.zoom` file
        // in Zoom put Zoom's unknown-source dialog on screen at every launch.
        // The list and the row's two buttons are the whole surface; nothing
        // opens Zoom but the learner's word, here or in the app.
        let (store, tmpPath) = try TestStores.mcp()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let tools = MCPToolRegistry(store: store).tools
        let list = try #require(tools.first { $0.name == "list_unconverted_zoom_recordings" })
        #expect((list.inputSchema["required"] as? [String])?.isEmpty == true)
        let resolve = try #require(tools.first { $0.name == "resolve_unconverted_zoom_recording" })
        #expect(resolve.inputSchema["required"] as? [String] == ["folder_path", "action"])
        let properties = try #require(resolve.inputSchema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == ["convert", "ignore", "unignore"])
        #expect(resolve.description.contains("Ask the learner before converting"))

        // The list answers this Mac's Zoom folders and never throws, whatever is in them.
        let listed = try #require(
            try JSONSerialization.jsonObject(with: Data(try await store.listUnconvertedZoomRecordings().utf8)) as? [String: Any]
        )
        let recordings = try #require(listed["recordings"] as? [[String: Any]])
        #expect(listed["count"] as? Int == recordings.count)
        #expect(listed["folders"] is [String])
        for row in recordings {
            #expect(row["folder_path"] is String && row["title"] is String && row["started_at"] is String)
            #expect(row["ignored"] is Bool)
        }

        // A folder the scan did not list is refused before anything is opened or written,
        // whatever the action; so is an action the row does not have.
        let unknown = "/nowhere/2026-01-01 00.00.00 Nobody"
        for action in ["convert", "ignore", "unignore", "delete"] {
            await #expect(throws: MCPError.self) {
                _ = try await store.resolveUnconvertedZoomRecording(folderPath: unknown, action: action)
            }
        }
    }

    /// Automatic audio over MCP — its only surface since 2026-09-22. The product owner (2026-09-20):
    /// "always generate audio for explainers" — the switch has to be readable
    /// and settable from an assistant like every other setting, and the
    /// explainers' switch is one of five, keyed by the automation kind. The
    /// voice is handed in rather than read from this Mac's Keychain, so the
    /// gate the pane applies — free always, paid behind consent — is pinned
    /// deterministically.
    @Test("get_automatic_audio_settings and set_automatic_audio_settings drive automatic audio")
    func automaticAudioSettingsToolsDriveTheTextToSpeechPane() async throws {
        // The paid voice is priced by OpenRouter's catalog, which unit tests
        // pin (`AudioPriceFixture`) rather than read.
        try await OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let (store, tmpPath) = try TestStores.mcp()
            defer { cleanup(tmpPath) }
            let defaults = UserDefaults.standard
            var keys = SourceAudioAutomation.automatable.map(\.preferenceKey)
            keys += SourceAudioAutomation.automatableSourceTypes.compactMap {
                SourceAudioAutomation.constraintPreferenceKey(for: $0)
            }
            keys.append(SourceAudioAutomation.paidVoiceConsentPreferenceKey)
            let prior = keys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in prior {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
            for key in keys { defaults.removeObject(forKey: key) }

            let free = AutomaticAudioSelection(
                provider: .openRouter, model: "deepgram/flux-tts:free", voice: "aura", allowsPaidVoices: false
            )
            let paid = AutomaticAudioSelection(
                provider: .openRouter, model: "hexgrad/kokoro-82m", voice: "af_heart", allowsPaidVoices: false
            )
            func object(_ json: String) throws -> [String: Any] {
                try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            }
            func rows(_ json: String) throws -> [String: [String: Any]] {
                let kinds = try #require(try object(json)["kinds"] as? [[String: Any]])
                return Dictionary(uniqueKeysWithValues: kinds.map { ($0["kind"] as! String, $0) })
            }

            // Read: one row per kind in the pane's order, the explainers' among
            // them, every switch off, and a free voice that may run.
            let initialJSON = try await store.getAutomaticAudioSettings(selection: free)
            let initial = try object(initialJSON)
            let kindOrder = try #require(initial["kinds"] as? [[String: Any]]).map { $0["kind"] as? String }
            #expect(kindOrder == ["article", "paper", "book", "course", "explainer"])
            let initialRows = try rows(initialJSON)
            #expect(initialRows["explainer"]?["enabled"] as? Bool == false)
            #expect(initialRows["explainer"]?["title"] as? String == "Explainers")
            #expect(initialRows["explainer"]?["filter"] as? String == "")
            #expect(initial["automation_available"] as? Bool == true)
            #expect(initial["allow_paid_voices"] as? Bool == false)
            #expect(initial["settings_pane"] == nil)
            #expect((initial["voice"] as? [String: Any])?["rate"] as? String == "free")

            // Explainers on, by the pane's plural: the explainers' key alone moves,
            // and generate_explainer's rule now says the audio starts unasked.
            let armed = try object(try await store.setAutomaticAudioSettings(
                kind: "explainers", enabled: true, filter: nil, allowPaidVoices: nil, selection: free
            ))
            #expect(armed["updated"] as? Bool == true)
            #expect(armed["changed"] as? [String] == ["enabled"])
            #expect((armed["kind"] as? [String: Any])?["enabled"] as? Bool == true)
            #expect(defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))
            #expect(!defaults.bool(forKey: SourceAudioAutomation.articlesPreferenceKey))
            #expect(MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(
                kind: SourceAudioAutomation.explainerKind, selection: free
            ))
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: "article", selection: free))

            // A no-op write reports nothing changed; off by the switch title.
            let same = try object(try await store.setAutomaticAudioSettings(
                kind: "explainer", enabled: true, filter: nil, allowPaidVoices: nil, selection: free
            ))
            #expect(same["updated"] as? Bool == false)
            _ = try await store.setAutomaticAudioSettings(
                kind: "Explainers", enabled: false, filter: nil, allowPaidVoices: nil, selection: free
            )
            #expect(!defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))

            // A paid voice without consent cannot arm a switch — the pane's switch
            // is disabled in that state — and the reader says why.
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(
                    kind: "explainer", enabled: true, filter: nil, allowPaidVoices: nil, selection: paid
                )
            }
            #expect(!defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))
            let priced = try object(try await store.getAutomaticAudioSettings(selection: paid))
            #expect(priced["automation_available"] as? Bool == false)
            #expect((priced["unavailable_reason"] as? String)?.contains("Allow paid voices") == true)
            #expect((priced["voice"] as? [String: Any])?["requires_paid_consent"] as? Bool == true)
            #expect(priced["paid_consent_quote"] is [String: Any])

            // Consent granted in the same call arms the switch on the paid voice.
            let consented = try object(try await store.setAutomaticAudioSettings(
                kind: "explainer", enabled: true, filter: nil, allowPaidVoices: true, selection: paid
            ))
            #expect(consented["changed"] as? [String] == ["allow_paid_voices", "enabled"])
            #expect(defaults.bool(forKey: SourceAudioAutomation.paidVoiceConsentPreferenceKey))
            #expect(defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))
            #expect(consented["automation_available"] as? Bool == true)

            // An empty rule is a cleared rule and needs no model call.
            let cleared = try object(try await store.setAutomaticAudioSettings(
                kind: "paper", enabled: nil, filter: "   ", allowPaidVoices: nil, selection: free
            ))
            #expect(cleared["updated"] as? Bool == false)
            // The preview reads the test host's own library, so its count is
            // whatever that library holds; the rule it previews is the empty one.
            let clearedPreview = try #require(cleared["filter_preview"] as? [String: Any])
            #expect(clearedPreview["filter"] as? String == "")
            #expect((clearedPreview["matching_source_count"] as? Int ?? -1) >= 0)

            // Nothing to change, an unknown kind, and a switch without a kind are refused.
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(kind: "paper", enabled: nil, filter: nil, allowPaidVoices: nil, selection: free)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(kind: "podcast", enabled: true, filter: nil, allowPaidVoices: nil, selection: free)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(kind: nil, enabled: true, filter: nil, allowPaidVoices: nil, selection: free)
            }

            // Registered, and the schema's kind enum is the reader's kinds.
            let tools = MCPToolRegistry(store: MCPDataStore()).tools
            #expect(tools.contains { $0.name == "get_automatic_audio_settings" })
            let setter = try #require(tools.first { $0.name == "set_automatic_audio_settings" })
            let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
            let kind = try #require(properties["kind"] as? [String: Any])
            #expect(kind["enum"] as? [String] == MCPDataStore.automaticAudioKinds)
            #expect(MCPDataStore.automaticAudioKinds == ["article", "paper", "book", "course", "explainer"])
        }
    }

    /// `generate_explainer` writes through the same pipeline the Mac's Explain
    /// button uses, with the writer handed in; the audio step is the switch's
    /// business and is pinned by `ArticleSpeechContentTests`
    /// (`explainerAudioStartsWithoutConfirmationOnlyBehindItsSwitch`), because
    /// starting it here would reach the speech queue.
    @Test("generate_explainer saves the script beside its source with the writer handed in")
    func generateExplainerWritesTheScriptWithAnInjectedWriter() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(
            kstore, id: "mito-1", url: "https://example.org/mito", title: "Mitochondria explained", sourceType: .article,
            content: "The full text of the article, long enough for a writer to work with."
        )

        let written = try await store.generateExplainer(
            sourceID: "mito-1",
            lengthName: "brief",
            generateAudio: false,
            confirmCost: false,
            backend: CannedMCPExplainerBackend(
                draft: ExplainerDraft(title: "Why mitochondria matter", script: "They make the energy.\n\nAnd more.")
            )
        )
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        #expect(payload["status"] as? String == "written")
        #expect(payload["explains_source_id"] as? String == "mito-1")
        #expect(payload["length"] as? String == "brief")
        #expect(payload["replaced_existing"] as? Bool == false)
        #expect(payload["audio"] == nil)
        let explainerID = try #require(payload["explainer_source_id"] as? String)
        #expect(explainerID == GeneratedExplainer.sourceID(explaining: "mito-1"))
        let explainer = try #require(try kstore.loadSourceForSync(explainerID))
        #expect(explainer.title == "Explainer: Mitochondria explained")
        #expect(explainer.sourceType == .article)
        #expect(explainer.audioAutomationKind == SourceAudioAutomation.explainerKind)
    }

    /// Settings › API Keys over MCP. The reader is pinned against
    /// a test-only key so the developer's Keychain never decides the outcome,
    /// and every refused write is one that throws before `ManagedAI.setOwnKey`
    /// runs — a real write here would store a key in the iCloud Keychain.
    @Test("get_own_router_key and set_own_router_key are Settings › API Keys")
    func ownRouterKeyToolsDriveTheAIUsagePane() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        func payload(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        // No key: nothing pays (ForeverLM pays for no AI), and the reader
        // still names the router and where to get a key for it.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        let none = try payload(try store.getOwnRouterKey())
        #expect(none["configured"] as? Bool == false)
        #expect(none["router"] is NSNull)
        #expect((none["billed_to"] as? String)?.hasPrefix("nobody") == true)
        #expect((none["billed_to"] as? String)?.contains("the learner's own OpenRouter key") == true)
        #expect(none["own_key_allowed"] == nil, "the key runs for every account; nothing gates it")
        let routers = try #require(none["routers"] as? [[String: Any]])
        #expect(routers.map { $0["id"] as? String } == ["openrouter"])
        #expect(routers.allSatisfy { ($0["keys_url"] as? String)?.hasPrefix("https://") == true })
        // OpenRouter also carries the text-to-speech voices and the speech-to-text
        // models, and the key pays for those; a plugin told "text models" would
        // quote the learner the wrong bill.
        let openRouterRow = try #require(routers.first { $0["id"] as? String == "openrouter" })
        #expect(openRouterRow["key_pays_for"] as? String == "text, voices, speech-to-text, images and video")
        #expect(openRouterRow["balance_still_pays_for"] == nil)

        // A stored key: the router, its label and the last four characters,
        // and never the key itself.
        let secret = "sk-or-v1-test-only-key-ABCD"
        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: secret))
        let storedJSON = try store.getOwnRouterKey()
        #expect(!storedJSON.contains(secret))
        let stored = try payload(storedJSON)
        #expect(stored["configured"] as? Bool == true)
        #expect(stored["router"] as? String == "openrouter")
        #expect(stored["router_label"] as? String == "OpenRouter")
        #expect(stored["key_suffix"] as? String == "ABCD")
        #expect(stored["key_pays_for"] as? String == "text, voices, speech-to-text, images and video")
        #expect(stored["billed_to"] as? String == "OpenRouter account")

        // Refused before anything is written: an unknown router, key beside
        // clear, a store with no key, and a paste that is not a key.
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "anthropic", key: "sk-something-long", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "otherrouter", key: "sk-something-long", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "sk-something-long", clear: true) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "   ", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "short", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "has a space in it", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "non-ascii-ключ-1234", clear: false) }

        // Registered: the reader on the read-only list, the writer's router enum
        // the same ids the reader reports, and the desktop-only gateway list
        // carries both (`workers/shared/public-mcp-tools.ts`).
        let registry = MCPToolRegistry(store: MCPDataStore())
        #expect(registry.tools.contains { $0.name == "get_own_router_key" })
        let setter = try #require(registry.tools.first { $0.name == "set_own_router_key" })
        let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
        let router = try #require(properties["router"] as? [String: Any])
        #expect(router["enum"] as? [String] == ManagedAI.OwnKeyRouter.allCases.map(\.rawValue))
        #expect(setter.inputSchema["required"] as? [String] == ["router"])
    }

    @Test("save_animation keeps the files in the library like a site, files the record under Animations linked to its sources, writes a player page around a lone video, reads a local file, updates by id, and refuses a Site's id")
    func mcpSaveAnimation() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let paperURL = "https://doi.org/10.1093/cvr/cvaf001"
        // Seeded as articles rather than papers: a ready paper needs the metadata
        // and content-cleanup attestations, which this test has no interest in.
        // The address is what the resolution being tested reads.
        try Self.seedReadySource(kstore, id: "src-empa-1", url: paperURL, title: "Empagliflozin improves cardiac energetics", sourceType: .article)
        try Self.seedReadySource(kstore, id: "src-other-1", url: "https://example.com/other", title: "Another paper", sourceType: .article)
        func files(_ id: String) async throws -> [SiteFile] {
            try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: id))
        }

        // A new animation: SVG that plays, about the paper named three ways —
        // by id, by its address, and by a token nothing answers to. No account
        // is needed; nothing is hosted.
        let html = """
        <!doctype html><html><head><title>EMPA and the TCA cycle</title></head>
        <body><h1>EMPA and the TCA cycle</h1><svg id="cycle"></svg><button id="play">Play</button>
        <p><a href="foreverlm://source/src-empa-1">Empagliflozin improves cardiac energetics</a></p>
        <script>document.getElementById("play").onclick = () => {};</script></body></html>
        """
        let saved = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "EMPA and the TCA cycle",
            description: "How empagliflozin shifts substrate use in the TCA cycle, with and without the drug.",
            html: html, files: nil,
            sources: ["src-empa-1", paperURL, "nope-xyz"],
            homeNotebookID: nil, notebookIDs: []
        ))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["section"] as? String == "animations")
        let animationID = try #require(saved["animation_id"] as? String)
        #expect(saved["url"] as? String == "foreverlm-site://\(animationID)/")
        #expect(saved["player_page_written"] as? Bool == false)
        let sources = try #require(saved["sources"] as? [[String: Any]])
        #expect(sources.count == 1, "the id and the address name one source")
        #expect(sources.first?["id"] as? String == "src-empa-1")
        #expect(sources.first?["title"] as? String == "Empagliflozin improves cardiac energetics")
        #expect(saved["unresolved_sources"] as? [String] == ["nope-xyz"])
        #expect(saved["source_cards"] as? Int == 1, "the page's source link is drawn as the card")
        let doc = try #require(saved["doc"] as? [String: Any])
        #expect(doc["kind"] as? String == "animation")
        #expect(doc["section"] as? String == "animations")
        #expect(doc["source_ids"] as? [String] == ["src-empa-1"])
        #expect(doc["id"] as? String == animationID)
        let message = try #require(saved["message"] as? String)
        #expect(message.contains("under Animations"))
        #expect(message.contains("linked to 1 source: Empagliflozin improves cardiac energetics"))
        #expect(message.contains("No library source answers to nope-xyz"))
        #expect(try await files(animationID).map(\.path) == ["foreverlm/source-cards.js", "index.html"])

        // The library holds the record as an animation, and the text copy is
        // the description, the page's words and the source's name.
        let records = try await store.notebookFileStorage.loadArtifacts(notebookID: nil)
        let record = try #require(records.first { $0.id == animationID })
        #expect(record.kind == .animation)
        #expect(record.section == .animations)
        #expect(record.sourceIDs == ["src-empa-1"])
        #expect(record.linkedKind == .foreverlmSite)
        let copy = try parseJSON(try await store.readArtifact(artifactID: animationID))
        let markdown = try #require(copy["markdown"] as? String)
        #expect(markdown.hasPrefix("How empagliflozin shifts substrate use"))
        #expect(markdown.contains("Play"))
        #expect(markdown.contains("About: Empagliflozin improves cardiac energetics"))

        // list_animations answers for the whole library and for one source.
        let all = try parseJSON(try await store.listAnimations(sourceID: nil))
        #expect(all["animation_count"] as? Int == 1)
        let byPaper = try parseJSON(try await store.listAnimations(sourceID: "foreverlm://source/src-empa-1"))
        #expect(byPaper["animation_count"] as? Int == 1)
        #expect(byPaper["source_title"] as? String == "Empagliflozin improves cardiac energetics")
        let entry = try #require((byPaper["animations"] as? [[String: Any]])?.first)
        #expect(entry["url"] as? String == "foreverlm-site://\(animationID)/")
        #expect((entry["summary"] as? String)?.hasPrefix("How empagliflozin") == true)
        let byOther = try parseJSON(try await store.listAnimations(sourceID: "src-other-1"))
        #expect(byOther["animation_count"] as? Int == 0)
        do {
            _ = try await store.listAnimations(sourceID: "nothing-here-at-all")
            Issue.record("an unknown source was accepted")
        } catch {
            #expect(error.localizedDescription.contains("No library source answers"))
        }

        // A new animation whose sources resolve to nothing is refused; one
        // about no source is saved and says so.
        do {
            _ = try await store.saveAnimation(
                animation: nil, title: "Nowhere", description: nil, html: "<h1>x</h1>", files: nil,
                sources: ["zzz-not-a-source"], homeNotebookID: nil, notebookIDs: []
            )
            Issue.record("unresolved sources were accepted on a new animation")
        } catch {
            #expect(error.localizedDescription.contains("No library source answers to zzz-not-a-source"))
        }

        // A lone video gets a player page, kept beside the video.
        let video = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "Electron flow", description: "Rendered with Manim.",
            html: nil, files: [["path": "flow.mp4", "content_base64": Data(repeating: 1, count: 64).base64EncodedString()]],
            sources: [], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(video["player_page_written"] as? Bool == true)
        #expect((video["message"] as? String)?.contains("about no library source") == true)
        let videoID = try #require(video["animation_id"] as? String)
        let videoFiles = try await files(videoID)
        #expect(videoFiles.map(\.path) == ["flow.mp4", "index.html"])
        let player = try #require(videoFiles.first { $0.path == "index.html" }.flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(player.contains("<source src=\"flow.mp4\" type=\"video/mp4\">"))
        #expect(player.contains("<h1>Electron flow</h1>"))

        // A file on this Mac is read from disk; one too big to sync with the
        // record is refused by name.
        let render = URL(fileURLWithPath: tmpPath).appendingPathComponent("tca-render.mp4")
        try Data(repeating: 2, count: 2_200_000).write(to: render)
        let local = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "TCA render", description: nil, html: nil,
            files: [["local_path": render.path]],
            sources: ["src-empa-1"], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(local["player_page_written"] as? Bool == true)
        let localID = try #require(local["animation_id"] as? String)
        #expect(try await files(localID).first { $0.path == "tca-render.mp4" }?.data.count == 2_200_000)
        let huge = URL(fileURLWithPath: tmpPath).appendingPathComponent("huge.mp4")
        try Data(count: LocalSite.maxBytes + 1).write(to: huge)
        do {
            _ = try await store.saveAnimation(
                animation: nil, title: "Too big", description: nil, html: nil, files: [["local_path": huge.path]],
                sources: [], homeNotebookID: nil, notebookIDs: []
            )
            Issue.record("an animation too big to sync was saved")
        } catch {
            #expect(error.localizedDescription.contains("syncs through iCloud"))
        }

        // An update names the animation by id and carries only the files that
        // change: the stored page is kept, the generated script remade, and the
        // sources stay as they were when none are passed.
        let updated = try parseJSON(try await store.saveAnimation(
            animation: animationID, title: nil, description: nil, html: nil,
            files: [["path": "styles.css", "content": "svg { width: 100%; }"]],
            sources: [], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(updated["status"] as? String == "updated")
        #expect(updated["kept_files"] as? [String] == ["index.html"])
        #expect((updated["doc"] as? [String: Any])?["source_ids"] as? [String] == ["src-empa-1"])
        #expect(try await files(animationID).map(\.path) == ["foreverlm/source-cards.js", "index.html", "styles.css"])

        // An update that names sources replaces them; the library address names it too.
        let regrounded = try parseJSON(try await store.saveAnimation(
            animation: "foreverlm-site://\(animationID)/", title: nil, description: nil, html: nil,
            files: [["path": "styles.css", "content": "svg { width: 90%; }"]],
            sources: ["src-other-1"], homeNotebookID: nil, notebookIDs: []
        ))
        #expect((regrounded["doc"] as? [String: Any])?["source_ids"] as? [String] == ["src-other-1"])
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).first { $0.id == animationID }?.sourceIDs == ["src-other-1"])

        // A Site's id is refused by both the maker and the remover.
        let site = try parseJSON(try await store.saveSite(
            site: nil, title: "Atlas", html: "<h1>Atlas</h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil,
            homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require(site["site_id"] as? String)
        #expect((site["doc"] as? [String: Any])?["kind"] as? String == "foreverlm_site")
        #expect((site["doc"] as? [String: Any])?["section"] as? String == "sites")
        do {
            _ = try await store.saveAnimation(
                animation: siteID, title: nil, description: nil, html: "<h1>x</h1>", files: nil,
                sources: [], homeNotebookID: nil, notebookIDs: []
            )
            Issue.record("a Site was updated as an animation")
        } catch {
            #expect(error.localizedDescription.contains("is a Site, not an animation"))
        }
        do {
            _ = try await store.deleteAnimation(animation: siteID)
            Issue.record("a Site was deleted as an animation")
        } catch {
            #expect(error.localizedDescription.contains("is a Site, not an animation"))
        }

        // delete_animation removes the entry with its files.
        let deleted = try parseJSON(try await store.deleteAnimation(animation: animationID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["animation_id"] as? String == animationID)
        let remaining = try await store.notebookFileStorage.loadArtifacts(notebookID: nil)
        #expect(!remaining.contains { $0.id == animationID })
        #expect(try await store.notebookFileStorage.localSiteFiles(artifactID: animationID) == nil, "the files go with the entry")
        #expect(remaining.filter(\.isAnimation).count == 2, "the video and the render stay")
        #expect(remaining.contains { $0.linkedKind == .foreverlmSite && !$0.isAnimation }, "the Site stays")

        // The registry, and the study chat's surface.
        #expect(Set(MCPToolRegistry.shared.tools.map(\.name)).isSuperset(of: ["save_animation", "list_animations", "delete_animation"]))
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: ["save_animation", "list_animations", "delete_animation"]))
    }

    // MARK: - Spaces of pages and a page's versions (docs/docs-design.md, "The Space", "Version history")

    /// The space rows bound to a throwaway defaults suite for this task
    /// (`PageSpaceRows.overrideDefaults`), never the standard defaults the
    /// Dev build and parallel suites share.
    private func withPageSpaceDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "MCPDataStoreTests.pageSpaces.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await PageSpaceRows.$overrideDefaults.withValue(PageSpaceRows.DefaultsOverride(defaults: defaults)) {
            try await body(defaults)
        }
    }

    private func createdDocID(_ store: MCPDataStore, title: String, markdown: String) async throws -> String {
        let created = try parseJSON(try await store.createArtifact(
            title: title, homeNotebookID: nil, notebookIDs: [], markdown: markdown
        ))
        return try #require((created["doc"] as? [String: Any])?["id"] as? String)
    }

    /// A team's page, in a team this account owns and may write.
    func createdTeamPage(_ store: MCPDataStore, markdown: String) async throws -> ArtifactMarkdownSnapshot {
        let now = Date()
        try store.knowledgeStore().saveTeam(TeamRecord(
            id: "team-pages", name: "Pages team", role: .owner, permission: .readWrite,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: "team-pages"), zoneOwnerRecordName: nil,
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        return try await store.notebookFileStorage.createArtifact(
            title: "The team's page", homeNotebookID: nil, linkedNotebookIDs: [], markdown: markdown, teamID: "team-pages"
        )
    }

    @Test("update_space makes, fills, moves, renames and deletes a space; list_spaces and list_docs read it")
    func mcpPageSpaces() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let aging = try await createdDocID(store, title: "Aging clocks", markdown: "# Aging clocks")
        let bio = try await createdDocID(store, title: "Bioelectric fields", markdown: "# Bioelectric fields")
        let trashed = try await createdDocID(store, title: "Old draft", markdown: "# Old draft")

        try await withPageSpaceDefaults { defaults in
            let created = try parseJSON(try await store.updatePageSpace(
                action: "create", spaceID: nil, name: "  🔬 Research \n project ", docIDs: [bio, bio, trashed]
            ))
            let space = try #require(created["space"] as? [String: Any])
            let id = try #require(space["id"] as? String)
            #expect(id.hasPrefix(PageSpaces.idPrefix))
            #expect(space["name"] as? String == "🔬 Research project")
            #expect(created["moved_doc_ids"] as? [String] == [bio, trashed], "each Doc once")
            #expect(defaults.string(forKey: PageSpaces.nameKey(spaceID: id)) == "🔬 Research project")
            #expect(defaults.string(forKey: PageSpaces.membershipKey(pageID: bio)) == id)

            // A page in the Trash stays in its space but is not listed there.
            _ = try await store.updateArtifact(artifactID: trashed, title: nil, homeNotebookID: nil, notebookIDs: nil, isArchived: true)
            let moved = try parseJSON(try await store.updatePageSpace(
                action: "move_docs", spaceID: id, name: nil, docIDs: [aging]
            ))
            let movedRow = try #require(moved["space"] as? [String: Any])
            let movedDocs = try #require(movedRow["docs"] as? [[String: Any]])
            #expect(movedDocs.map { $0["id"] as? String } == [aging, bio], "by title, the Trash left out")
            #expect(movedDocs.first?["kind"] as? String == "markdown")
            #expect(movedRow["doc_count"] as? Int == 2)

            // list_docs names each Doc's space.
            let listing = try parseJSON(try await store.listArtifacts(notebookID: nil))
            let docs = try #require(listing["docs"] as? [[String: Any]])
            #expect(docs.first { $0["id"] as? String == aging }?["space_id"] as? String == id)
            #expect(docs.first { $0["id"] as? String == aging }?["space_name"] as? String == "🔬 Research project")

            // A page is in one space at a time: moving it to a second takes it out of the first.
            let second = try parseJSON(try await store.updatePageSpace(
                action: "create", spaceID: nil, name: "Reading group", docIDs: [aging]
            ))
            let secondID = try #require((second["space"] as? [String: Any])?["id"] as? String)
            #expect(defaults.string(forKey: PageSpaces.membershipKey(pageID: aging)) == secondID)

            _ = try await store.updatePageSpace(action: "rename", spaceID: id, name: "Labs", docIDs: nil)
            let listed = try parseJSON(try await store.listPageSpaces())
            let rows = try #require(listed["spaces"] as? [[String: Any]])
            #expect(rows.map { $0["name"] as? String } == ["Labs", "Reading group"], "by name")
            #expect((rows.first?["docs"] as? [[String: Any]])?.map { $0["id"] as? String } == [bio])

            let removed = try parseJSON(try await store.updatePageSpace(
                action: "remove_docs", spaceID: nil, name: nil, docIDs: [aging]
            ))
            #expect(removed["removed_doc_ids"] as? [String] == [aging])
            #expect(defaults.object(forKey: PageSpaces.membershipKey(pageID: aging)) == nil)

            let deleted = try parseJSON(try await store.updatePageSpace(
                action: "delete", spaceID: id, name: nil, docIDs: nil
            ))
            #expect(deleted["deleted"] as? Bool == true)
            #expect(defaults.object(forKey: PageSpaces.nameKey(spaceID: id)) == nil)
            #expect(defaults.object(forKey: PageSpaces.membershipKey(pageID: bio)) == nil)
            #expect(defaults.object(forKey: PageSpaces.membershipKey(pageID: trashed)) == nil)
            let after = try parseJSON(try await store.listPageSpaces())
            #expect((after["spaces"] as? [[String: Any]])?.map { $0["id"] as? String } == [secondID])
            let remaining = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).map(\.id)
            #expect(Set(remaining).isSuperset(of: [aging, bio, trashed]), "the pages stay")
            let relisted = try parseJSON(try await store.listArtifacts(notebookID: nil))
            #expect((relisted["docs"] as? [[String: Any]])?.first { $0["id"] as? String == bio }?["space_id"] is NSNull)
        }
    }

    @Test("update_space trash and restore: a space in Trash leaves list_spaces for in_trash, takes no pages, and comes back with them")
    func mcpPageSpaceTrash() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let page = try await createdDocID(store, title: "Field notes", markdown: "# Field notes")

        try await withPageSpaceDefaults { defaults in
            let created = try parseJSON(try await store.updatePageSpace(action: "create", spaceID: nil, name: "Lab", docIDs: [page]))
            let id = try #require((created["space"] as? [String: Any])?["id"] as? String)

            let trashed = try parseJSON(try await store.updatePageSpace(action: "trash", spaceID: id, name: nil, docIDs: nil))
            #expect(trashed["in_trash"] as? Bool == true)
            #expect(defaults.string(forKey: PageSpaces.trashKey(spaceID: id)) != nil)
            #expect(defaults.string(forKey: PageSpaces.membershipKey(pageID: page)) == id, "its pages keep their rows")
            let listed = try parseJSON(try await store.listPageSpaces())
            #expect((listed["spaces"] as? [[String: Any]])?.isEmpty == true)
            #expect((listed["in_trash"] as? [[String: Any]])?.map { $0["id"] as? String } == [id])
            do {
                _ = try await store.updatePageSpace(action: "move_docs", spaceID: id, name: nil, docIDs: [page])
                Issue.record("a space in Trash took a page")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("Trash"))
            }

            let restored = try parseJSON(try await store.updatePageSpace(action: "restore", spaceID: id, name: nil, docIDs: nil))
            #expect(restored["in_trash"] as? Bool == false)
            #expect(defaults.object(forKey: PageSpaces.trashKey(spaceID: id)) == nil)
            let back = try parseJSON(try await store.listPageSpaces())
            #expect(((back["spaces"] as? [[String: Any]])?.first?["docs"] as? [[String: Any]])?.map { $0["id"] as? String } == [page])
            do {
                _ = try await store.updatePageSpace(action: "restore", spaceID: id, name: nil, docIDs: nil)
                Issue.record("a space in use was restored")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("not in the Space's Trash"))
            }
        }
    }

    @Test("update_space refuses an unknown action, a blank name, a missing space, an unknown Doc and a team's page, writing nothing")
    func mcpPageSpaceRefusals() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let page = try await createdDocID(store, title: "Mine", markdown: "# Mine")
        let team = try await createdTeamPage(store, markdown: "# Team")

        try await withPageSpaceDefaults { _ in
            func refused(_ action: String, _ spaceID: String?, _ name: String?, _ docIDs: [String]?, _ phrase: String) async {
                do {
                    _ = try await store.updatePageSpace(action: action, spaceID: spaceID, name: name, docIDs: docIDs)
                    Issue.record("\(action) was accepted")
                } catch let error as MCPError {
                    #expect(error.localizedDescription.contains(phrase), "\(error.localizedDescription)")
                } catch {
                    Issue.record("unexpected \(error)")
                }
            }
            await refused("archive", nil, "X", nil, "action must be")
            await refused("create", nil, "  ", [page], "name is required")
            await refused("create", nil, "Research", ["not-a-doc"], "Doc not found")
            await refused("create", nil, "Research", [page, team.artifact.id], "team's record")
            await refused("rename", "psp-missing", "X", nil, "Space not found")
            await refused("delete", nil, nil, nil, "space_id is required")
            #expect(PageSpaceRows.read() == PageSpaces(), "a refusal writes nothing")

            let created = try parseJSON(try await store.updatePageSpace(action: "create", spaceID: nil, name: "Research", docIDs: nil))
            let id = try #require((created["space"] as? [String: Any])?["id"] as? String)
            await refused("move_docs", id, nil, [], "doc_ids is required")
            await refused("remove_docs", nil, nil, nil, "doc_ids is required")
            #expect(PageSpaceRows.read().pageIDs([page, team.artifact.id], in: id).isEmpty)

            // Every Setting has an MCP route; a space's rows have theirs here, never set_app_setting.
            #expect(Set(MCPToolRegistry().tools.map(\.name)).isSuperset(of: ["list_spaces", "update_space"]))
            let settings = await MainActor.run { MCPDataStore.appSettingsCatalog().map { ($0.id, $0.preferenceKeys) } }
            for (id, keys) in settings {
                #expect(!keys.contains {
                    $0.hasPrefix(PageSpaces.namePreferenceKeyPrefix) || $0.hasPrefix(PageSpaces.membershipPreferenceKeyPrefix)
                }, "set_app_setting's \(id) writes a space's row")
            }
        }
    }

    @Test("list_doc_versions lists this Mac's versions newest first and reads one; restore_doc_version restores and keeps the body it replaced")
    func mcpDocVersions() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let docID = try await createdDocID(store, title: "Landscape", markdown: "# Landscape\n\nOne.")
        let empty = try parseJSON(try await store.listDocVersions(artifactID: docID))
        #expect(empty["version_count"] as? Int == 0)
        #expect(empty["can_restore"] as? Bool == true)

        // Two assistant writes: each keeps the body it replaced.
        let revision1 = try #require(try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String)
        let written = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Landscape\n\nTwo.", expectedRevision: revision1
        ))
        let revision2 = try #require(written["revision"] as? String)
        _ = try await store.writeArtifact(artifactID: docID, markdown: "# Landscape\n\nThree.", expectedRevision: revision2)

        let listed = try parseJSON(try await store.listDocVersions(artifactID: docID))
        #expect(listed["version_count"] as? Int == 2)
        let versions = try #require(listed["versions"] as? [[String: Any]])
        #expect(versions.map { $0["reason"] as? String } == ["assistant_edit", "assistant_edit"])
        #expect(versions.first?["summary"] as? String == "Before an AI edit")
        #expect(versions.first?["bytes"] as? Int == "# Landscape\n\nTwo.".utf8.count)
        let current = try #require(listed["current"] as? [String: Any])
        #expect(current["characters"] as? Int == "# Landscape\n\nThree.".count)
        let oldestID = try #require(versions.last?["version_id"] as? String)

        // One version's text, whole and by range.
        let read = try parseJSON(try await store.listDocVersions(artifactID: docID, versionID: oldestID))
        #expect((read["version"] as? [String: Any])?["markdown"] as? String == "# Landscape\n\nOne.")
        let ranged = try parseJSON(try await store.listDocVersions(artifactID: docID, versionID: oldestID, start: 13, length: 4))
        #expect((ranged["version"] as? [String: Any])?["markdown"] as? String == "One.")
        #expect((ranged["version"] as? [String: Any])?["is_complete"] as? Bool == false)

        // A stale revision and an unknown version are refused, and nothing changes.
        await #expect(throws: MCPError.self) {
            _ = try await store.restoreDocVersion(artifactID: docID, versionID: oldestID, expectedRevision: revision1)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.restoreDocVersion(artifactID: docID, versionID: "1-learnerEdit.md")
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nThree.")

        // The restore writes the version and keeps "Three." as a restore version, which undoes it.
        let restored = try parseJSON(try await store.restoreDocVersion(
            artifactID: docID, versionID: oldestID, expectedRevision: current["revision"] as? String
        ))
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nOne.")
        #expect(restored["revision"] as? String == (try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String))
        let keptID = try #require(restored["replaced_body_version_id"] as? String)
        let afterRestore = try parseJSON(try await store.listDocVersions(artifactID: docID, versionID: keptID))
        #expect(afterRestore["version_count"] as? Int == 3)
        #expect((afterRestore["version"] as? [String: Any])?["reason"] as? String == "restore")
        #expect((afterRestore["version"] as? [String: Any])?["markdown"] as? String == "# Landscape\n\nThree.")
        _ = try await store.restoreDocVersion(artifactID: docID, versionID: keptID)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nThree.")
    }

    @Test("restore_doc_version refuses a team's page and a linked page, as the app's Version History does")
    func mcpDocVersionRefusals() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        // A team's page: its versions are listed, never restored here.
        let team = try await createdTeamPage(store, markdown: "# Team\n\nOne.")
        _ = try await store.notebookFileStorage.writeArtifactMarkdown(
            artifactID: team.artifact.id, markdown: "# Team\n\nTwo.", expectedRevision: team.revision, versionReason: .assistantEdit
        )
        let listed = try parseJSON(try await store.listDocVersions(artifactID: team.artifact.id))
        #expect(listed["version_count"] as? Int == 1)
        #expect(listed["can_restore"] as? Bool == false)
        let versionID = try #require((listed["versions"] as? [[String: Any]])?.first?["version_id"] as? String)
        do {
            _ = try await store.restoreDocVersion(artifactID: team.artifact.id, versionID: versionID)
            Issue.record("a team's page was restored")
        } catch {
            #expect(error.localizedDescription.contains("team's page"), "\(error.localizedDescription)")
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: team.artifact.id))["markdown"] as? String == "# Team\n\nTwo.")

        // A linked page has no body of ForeverLM's own to restore.
        let linked = try parseJSON(try await store.linkPageArtifact(
            urlString: "https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d",
            title: "Atlas", text: "# Atlas", homeNotebookID: nil, notebookIDs: []
        ))
        let linkedID = try #require((linked["doc"] as? [String: Any])?["id"] as? String)
        #expect(try parseJSON(try await store.listDocVersions(artifactID: linkedID))["can_restore"] as? Bool == false)
        do {
            _ = try await store.restoreDocVersion(artifactID: linkedID, versionID: versionID)
            Issue.record("a linked page was restored")
        } catch {
            #expect(error.localizedDescription.contains("read-only copy"), "\(error.localizedDescription)")
        }
        #expect(Set(MCPToolRegistry().tools.map(\.name)).isSuperset(of: ["list_doc_versions", "restore_doc_version"]))
    }
}

#endif
