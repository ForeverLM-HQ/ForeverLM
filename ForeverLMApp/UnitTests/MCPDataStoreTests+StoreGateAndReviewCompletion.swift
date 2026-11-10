// MCPDataStoreTests: the store gate, review completion, transcripts and the Schedule read tools.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    @Test("Read-only tools share the store gate; a writer holds it alone, in arrival order")
    func storeGateSharesReadsAndSerializesWrites() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // Two readers hold the gate together.
        await store.acquireToolOperation(.shared)
        let secondReader = MCPTestSignal()
        let secondReaderTask = Task {
            await store.acquireToolOperation(.shared)
            await secondReader.signal()
        }
        await secondReaderTask.value
        #expect(await secondReader.hasSignaled)

        // A writer waits for both readers to leave...
        let writerAdmitted = MCPTestSignal()
        let writerReleased = MCPTestSignal()
        let writerTask = Task {
            await store.acquireToolOperation(.exclusive)
            await writerAdmitted.signal()
            await writerReleased.wait()
            await store.releaseToolOperation()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await writerAdmitted.hasSignaled))
        await store.releaseToolOperation()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await writerAdmitted.hasSignaled))

        // ...and a reader that arrives behind the queued writer waits for it,
        // so a stream of reads cannot starve a write.
        let lateReaderAdmitted = MCPTestSignal()
        let lateReaderTask = Task {
            await store.acquireToolOperation(.shared)
            await lateReaderAdmitted.signal()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await lateReaderAdmitted.hasSignaled))

        await store.releaseToolOperation()
        await writerAdmitted.wait()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await lateReaderAdmitted.hasSignaled))

        await writerReleased.signal()
        await writerTask.value
        await lateReaderTask.value
        #expect(await lateReaderAdmitted.hasSignaled)
        await store.releaseToolOperation()
    }

    @Test("A read-only tool runs while another reader holds the gate")
    func readOnlyToolDoesNotWaitForOtherReaders() async throws {
        // Until 2026-09-18 every tool held the gate alone, so a list_courses
        // queued behind whatever read happened to be running. A read cannot
        // leave uncommitted rows for another read to see, so it shares.
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let registry = MCPToolRegistry(store: store)

        await store.acquireToolOperation(.shared)
        let outcome = await registry.callToolDetailed(
            name: "list_courses",
            arguments: [:],
            access: .internalFullAccess
        )
        #expect(!outcome.isError)
        await store.releaseToolOperation()
    }

    @Test("Publishing tools share the gate; tools that write the cached connection hold it alone")
    func storeGateModeFollowsWhatAToolDoesToTheConnection() {
        #expect(MCPToolRegistry.storeGateMode(for: "list_teams") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "list_docs") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "read_site_file") == .shared)
        // A publish spends its time uploading and records the result through
        // the storage actor's own connection; a list_teams waited half a minute
        // behind one on 2026-09-18.
        #expect(MCPToolRegistry.storeGateMode(for: "publish_doc") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "unpublish_doc") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "create_notebook") == .exclusive)
        #expect(MCPToolRegistry.storeGateMode(for: "end_review_session") == .exclusive)
        #expect(MCPToolRegistry.storeGateMode(for: "delete_source") == .exclusive)
        let registered = Set(MCPToolRegistry.shared.tools.map(\.name))
        for name in MCPToolRegistry.sharedGateWritingToolNames.union(MCPToolRegistry.selfGatedToolNames) {
            #expect(registered.contains(name), "\(name) is not a registered tool")
        }
        // A tool is held by the dispatcher, exempt, or gated by itself: never two.
        #expect(MCPToolRegistry.selfGatedToolNames.isDisjoint(with: MCPToolRegistry.storeGateExemptToolNames))
        #expect(MCPToolRegistry.selfGatedToolNames.isDisjoint(with: MCPToolRegistry.sharedGateWritingToolNames))
        #expect(MCPToolRegistry.sharedGateWritingToolNames.isDisjoint(with: MCPToolRegistry.storeGateExemptToolNames))
    }

    /// On 2026-09-27 generate_course_quizzes held the gate alone for minutes of
    /// model calls, and an assistant could neither read a transcript nor save a
    /// quiz until it finished. Every paid tool is now off the dispatcher's gate
    /// except these, each of which writes back a whole row it read before its
    /// wait. Moving one off, or adding a paid tool, means checking what it does
    /// to the cached connection first.
    @Test("The long paid tools hold the store gate only around their own reads and writes")
    func paidToolsHoldTheGateOnlyAroundTheirStoreWork() {
        let offTheDispatcherGate = MCPToolRegistry.storeGateExemptToolNames
            .union(MCPToolRegistry.selfGatedToolNames)
            .union(MCPToolRegistry.settingsParityToolNames)
        #expect(MCPToolRegistry.paidWorkToolNames.subtracting(offTheDispatcherGate) == [
            "generate_source_audio", "import_teachable_course", "ingest_lecture_papers",
            "scan_meeting_for_mentioned_papers", "scan_article_for_linked_sources",
            "extract_paper_metadata", "extract_article_metadata",
            "import_connector_paper", "import_video_cited_paper",
            "make_article_reading_view",
        ])
        for name in [
            "generate_course_quizzes", "generate_walkthrough", "generate_explainer_video",
            "inspect_paper_figure", "generate_image",
        ] {
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name), "\(name) should never touch the cached connection")
        }
        for name in [
            "generate_course", "add_course_quiz_pictures", "add_textbook_to_course", "generate_explainer",
            "transcribe_meeting_recording", "fetch_video_transcript", "scan_video_for_cited_papers",
            "find_lecture_papers", "download_papers_needing_attention", "recheck_paywalled_papers",
            "import_local_pdf_as_paper", "import_local_file", "import_paper_from_url",
        ] {
            #expect(MCPToolRegistry.selfGatedToolNames.contains(name), "\(name) should gate only its own store stretches")
        }
    }

    @Test("Bulk quiz work is source-only until drawings are cost-confirmed")
    func bulkQuizPicturesDefaultToSourcePictures() throws {
        for (name, drawKey) in [
            ("add_course_quiz_pictures", "draw"),
            ("generate_course_quizzes", "draw_pictures"),
        ] {
            let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == name })
            let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
            let draw = try #require(properties[drawKey] as? [String: Any])
            let confirmation = try #require(properties["confirm_drawings"] as? [String: Any])

            #expect((draw["description"] as? String)?.contains("default false") == true)
            #expect((confirmation["description"] as? String)?.contains("explicitly agreed") == true)
            #expect(tool.description.contains("published maximum cost"))
            #expect(properties["approved_spend_usd"] != nil)
        }
    }

    @Test("A store stretch nested in a hold runs under it, and a read-only hold refuses a write")
    func storeGateStretchesNestUnderTheirHold() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // Inside a stretch held alone, a nested read or write runs at once
        // instead of queuing behind the stretch that holds the gate.
        let nested = try await store.withStoreGate(.exclusive) {
            try await store.withStoreGate(.shared) {
                try await store.withStoreGate(.exclusive) { 42 }
            }
        }
        #expect(nested == 42)

        // A reader that asks to write would wait on itself, so it is refused.
        await #expect(throws: MCPError.self) {
            try await store.withStoreGate(.shared) {
                try await store.withStoreGate(.exclusive) { 0 }
            }
        }

        // A task spawned inside a stretch inherits its hold; once the stretch
        // has ended, the task takes the gate itself rather than borrowing it.
        let stretchEnded = MCPTestSignal()
        let spawnedRan = MCPTestSignal()
        var spawned: Task<Bool, Never>?
        try await store.withStoreGate(.exclusive) {
            spawned = Task {
                await stretchEnded.wait()
                let ran = (try? await store.withStoreGate(.exclusive) { true }) ?? false
                await spawnedRan.signal()
                return ran
            }
        }
        // Both stretches released the gate, so a writer is admitted at once.
        await store.acquireToolOperation(.exclusive)
        await stretchEnded.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await spawnedRan.hasSignaled), "the spawned stretch ran on a hold that had ended")
        await store.releaseToolOperation()
        #expect(await spawned?.value == true)
    }

    @Test("A read and a quiz save both answer while a long paid writer waits on its model")
    func readsAndWritesRunBesideALongPaidWriter() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { cleanup(tmpDir.path) }
        let writerEntered = MCPTestSignal()
        let releaseWriter = MCPTestSignal()
        let store = MCPDataStore(
            dbPath: tmpDir.appendingPathComponent("knowledge.db").path,
            explainerBackend: HeldMCPExplainerBackend(
                entered: writerEntered,
                release: releaseWriter,
                draft: ExplainerDraft(title: "Why mitochondria matter", script: "They make the energy.\n\nAnd more.")
            )
        )
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(
            kstore, id: "mito-1", url: "https://example.org/mito", title: "Mitochondria explained", sourceType: .article,
            content: "The full text of the article, long enough for a writer to work with."
        )
        let learningPoint = "The proton circuit couples respiration to ATP synthesis through the membrane potential."
        try kstore.saveCourseGroup(name: "bioenergetics", metadata: CourseMetadata(title: "Bioenergetics"))
        let lecture = CourseSession(courseName: "bioenergetics", number: 1, title: "Proton circuits")
        try kstore.saveCourseLecture(lecture)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Proton circuits",
            sourceType: .video, discoveryOrigin: .manual, id: "video-one"
        )
        video.content = "[0:00] \(learningPoint)"
        video.state = .ready
        try kstore.saveSource(video)
        _ = try kstore.saveCourseLectureItem(CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0))
        let videoID = video.id
        let registry = MCPToolRegistry(store: store)

        // The paid writer: the explainer waits in its model call until released.
        let writerDone = MCPTestSignal()
        let writer = Task { () -> MCPToolRegistry.ToolCallOutcome in
            let outcome = await registry.callToolDetailed(
                name: "generate_explainer",
                arguments: ["source_id": "mito-1", "length": "brief", "generate_audio": false]
            )
            await writerDone.signal()
            return outcome
        }
        for _ in 0..<500 {
            if await writerEntered.hasSignaled { break }
            if await writerDone.hasSignaled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await writerEntered.hasSignaled else {
            await releaseWriter.signal()
            let early = await writer.value
            Issue.record("generate_explainer never reached its model call: \(early.text)")
            return
        }

        // The two calls the assistant could not make on 2026-09-27: reading a
        // transcript, and saving a quiz, which writes the cached connection.
        let readDone = MCPTestSignal()
        let read = Task { () -> MCPToolRegistry.ToolCallOutcome in
            let outcome = await registry.callToolDetailed(name: "get_source_content", arguments: ["source_id": videoID])
            await readDone.signal()
            return outcome
        }
        let saveDone = MCPTestSignal()
        let save = Task { () -> MCPToolRegistry.ToolCallOutcome in
            let outcome = await registry.callToolDetailed(name: "save_course_quiz", arguments: [
                "course_id": "bioenergetics",
                "learning_points": [learningPoint],
                "kind": "practice",
                "title": "Proton circuits",
                "lecture_ids": [lecture.id],
                "questions": [[
                    "question": "What couples respiration to ATP synthesis?",
                    "answer": "The membrane potential.",
                    "key_points": ["membrane potential"],
                    "points": [1],
                    "source_id": videoID,
                    "quote": "couples respiration to ATP synthesis through the membrane potential",
                ] as [String: Any]],
            ])
            await saveDone.signal()
            return outcome
        }
        // Behind a writer holding the gate for its whole run, neither would
        // answer before the writer is released below.
        var answeredWhileWriterWaited = false
        for _ in 0..<500 {
            if await readDone.hasSignaled, await saveDone.hasSignaled {
                answeredWhileWriterWaited = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let writerFinishedFirst = await writerDone.hasSignaled
        await releaseWriter.signal()
        let readOutcome = await read.value
        let saveOutcome = await save.value
        let writerOutcome = await writer.value

        #expect(answeredWhileWriterWaited, "a read and a write queued behind the paid writer")
        #expect(!writerFinishedFirst)
        #expect(!readOutcome.isError, "\(readOutcome.text)")
        #expect(readOutcome.text.contains("proton circuit"))
        #expect(!saveOutcome.isError, "\(saveOutcome.text)")
        #expect(try kstore.loadCourseQuizzes(courseID: "bioenergetics").count == 1)
        #expect(!writerOutcome.isError, "\(writerOutcome.text)")
        #expect(try kstore.loadSourceForSync(GeneratedExplainer.sourceID(explaining: "mito-1")) != nil)
    }

    /// 2026-10-13: an assistant's paid call outlasted the gateway's 60 s, it
    /// called again, and the Mac ran the same paid work twice side by side.
    @Test("A paid call made again while the first runs waits for it: one model call, both answered")
    func repeatedPaidCallJoinsTheRunningOne() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { cleanup(tmpDir.path) }
        let writes = CountingHeldExplainerBackend.Count()
        let releaseWriter = MCPTestSignal()
        let store = MCPDataStore(
            dbPath: tmpDir.appendingPathComponent("knowledge.db").path,
            explainerBackend: CountingHeldExplainerBackend(
                writes: writes,
                release: releaseWriter,
                draft: ExplainerDraft(title: "Why mitochondria matter", script: "They make the energy.\n\nAnd more.")
            )
        )
        let kstore = try store.knowledgeStore()
        let sourceID = "mito-repeat-\(UUID().uuidString.prefix(8))"
        try Self.seedReadySource(
            kstore, id: sourceID, url: "https://example.org/\(sourceID)", title: "Mitochondria explained", sourceType: .article,
            content: "The full text of the article, long enough for a writer to work with."
        )
        let registry = MCPToolRegistry(store: store)
        let arguments: [String: Any] = ["source_id": sourceID, "length": "brief", "generate_audio": false]
        let key = try #require(MCPToolRegistry.repeatedCallKey(
            name: "generate_explainer", arguments: arguments, hostSessionID: nil, access: .internalFullAccess
        ))

        let first = Task { await registry.callToolDetailed(name: "generate_explainer", arguments: arguments) }
        for _ in 0..<500 where writes.value == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard writes.value == 1 else {
            await releaseWriter.signal()
            let early = await first.value
            Issue.record("generate_explainer never reached its model call: \(early.text)")
            return
        }
        let second = Task { await registry.callToolDetailed(name: "generate_explainer", arguments: arguments) }
        for _ in 0..<500 where registry.repeatedCalls.callers(for: key) < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(registry.repeatedCalls.callers(for: key) == 2, "the second call did not join the first")
        #expect(MCPRunningWork.shared.snapshot.filter { $0.about == "source_id \(sourceID)" }.count == 1)

        await releaseWriter.signal()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        #expect(!firstOutcome.isError, "\(firstOutcome.text)")
        #expect(secondOutcome.text == firstOutcome.text)
        #expect(writes.value == 1, "the explainer was written \(writes.value) times")
        #expect(registry.repeatedCalls.callers(for: key) == 0)
    }

    @Test("Cached-store reads wait for atomic review completion")
    func cachedStoreReadWaitsForAtomicReviewCompletion() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let notebook = try knowledge.createCompanionGoal(
            title: "Isolation notebook",
            topic: "transaction isolation",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Isolation goal",
            topic: "transaction isolation",
            startAt: now,
            endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )
        let sessionID = "read-isolation-session"
        try knowledge.createReviewSession(
            id: sessionID,
            topic: "Read isolation",
            sourceIDs: [],
            startedAt: now,
            goalID: goal.id
        )
        let gapSummary = "Distinguish committed state from an in-flight review."
        let gap = LearningGoalGap(
            id: "read-isolation-gap",
            goalID: goal.id,
            summary: gapSummary,
            sourceID: nil,
            status: "open",
            severity: 0.5,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: nil,
            sessionID: sessionID
        )
        let registry = MCPToolRegistry(store: store)

        // Hold the same operation boundary that end_review_session owns, then
        // start a declared read which uses the cached KnowledgeStore connection.
        // It must remain queued until the complete SQLite transaction commits.
        await store.acquireToolOperation()
        let readStarted = MCPTestSignal()
        let readFinished = MCPTestSignal()
        let readTask = Task {
            await readStarted.signal()
            let outcome = await registry.callToolDetailed(
                name: "get_goal",
                arguments: ["goal_id": goal.id],
                access: .internalFullAccess
            )
            await readFinished.signal()
            return outcome
        }
        await readStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        let readFinishedBeforeCommit = await readFinished.hasSignaled
        #expect(!readFinishedBeforeCommit)

        do {
            try knowledge.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: sessionID,
                overallScore: 0.8,
                summary: "Atomic completion committed.",
                endedAt: now.addingTimeInterval(60),
                sessionSourceIDs: [],
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-10",
                companionGaps: [gap],
                attempts: []
            )
        } catch {
            await store.releaseToolOperation()
            throw error
        }
        await store.releaseToolOperation()

        let outcome = await readTask.value
        #expect(!outcome.isError)
        #expect(outcome.text.contains(gapSummary))
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.status == "completed")
    }

    @Test("endReviewSession atomically links MCP memory attempts to exact exchanges")
    func endReviewSessionLinksMemoryAttempts() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "A retrieval cue must be answered before feedback strengthens the trace."
        try insertSource(dbPath: dbPath, id: "source-memory", title: "Memory", content: content)
        try insertSource(
            dbPath: dbPath,
            id: "source-memory-untouched",
            title: "Untouched memory source",
            content: "This source is attached to the session but never attempted."
        )
        let item = MemoryItem(
            id: "memory-item",
            kind: .concept,
            target: "Explain retrieval-before-feedback",
            rubricJSON: #"{"criteria":["Explains effortful retrieval"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor",
                    memoryItemID: "memory-item",
                    sourceID: "source-memory",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ]
        )
        try store.knowledgeStore().saveMemoryItem(item)
        let id = "memory-review-linkage"
        try store.knowledgeStore().createReviewSession(
            id: id,
            topic: "Memory review",
            sourceIDs: ["source-memory", "source-memory-untouched"],
            cardIDs: [store.mcpMemoryItemCardID(item)]
        )

        let transcript = "Tutor: Why retrieve first?\nLearner: Effort exposes what I can actually access."
        let memoryAttempts: [[String: Any]] = [[
            "item_id": "memory-item",
            "prompt": "Why retrieve before seeing feedback?",
            "learner_answer": "Effort exposes what I can actually access.",
            "evaluation": "Correct; retrieval diagnoses and strengthens access.",
            "score": 0.8,
            "retrieval_quality": "independent",
            "missing_rubric_elements": [] as [String],
        ]]
        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.8,
            summary: "Understood retrieval before feedback.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        let exchangeID = try scalarString(
            dbPath: dbPath,
            "SELECT exchange_id FROM memory_attempts WHERE memory_item_id = 'memory-item'"
        )
        #expect(exchangeID != nil)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT question FROM review_exchanges WHERE id = '\(exchangeID ?? "")'"
        ) == "Why retrieve before seeing feedback?")
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT user_answer FROM review_exchanges WHERE id = '\(exchangeID ?? "")'"
        ) == "Effort exposes what I can actually access.")
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "completed")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'source-memory' AND completed_at IS NOT NULL"
        ) == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'source-memory-untouched'"
        ) == 0)

        let attemptCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts")
        let exchangeCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'")
        let schedule = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = 'memory-item'"
        )

        // Simulate the client losing the successful response and replaying the
        // exact end call. Durable history and scheduler state remain unchanged.
        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.8,
            summary: "Understood retrieval before feedback.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == attemptCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'") == exchangeCount)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = 'memory-item'"
        ) == schedule)
    }

    @Test("memoryReview never reintroduces a source anchored by a future active item")
    func memoryReviewExcludesAllActiveAnchors() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "An active concept already represents this source even when its next review is tomorrow."
        try insertSource(
            dbPath: dbPath,
            id: "source-future-memory",
            title: "Future concept",
            content: content
        )
        let knowledge = try store.knowledgeStore()
        let old = Date().addingTimeInterval(-90 * 86_400)
        try knowledge.createReviewSession(
            id: "legacy-review",
            topic: "Legacy source review",
            sourceIDs: ["source-future-memory"],
            startedAt: old
        )
        _ = try knowledge.addReviewExchange(
            sessionID: "legacy-review",
            question: "What did this source argue?",
            answer: "I barely remember.",
            evaluation: "Needs review.",
            score: 0.2,
            knowledgeNote: nil,
            sourceRefs: ["source-future-memory"],
            answeredAt: old
        )
        try knowledge.completeReviewSession(
            sessionID: "legacy-review",
            overallScore: 0.2,
            summary: "Weak legacy review.",
            endedAt: old
        )
        let future = Date().addingTimeInterval(86_400)
        let item = MemoryItem(
            id: "future-memory-item",
            kind: .concept,
            target: "Explain the represented concept",
            rubricJSON: #"{"criteria":["Explains the concept"]}"#,
            sources: [
                MemoryItemSource(
                    id: "future-memory-anchor",
                    memoryItemID: "future-memory-item",
                    sourceID: "source-future-memory",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ],
            createdAt: future,
            updatedAt: future
        )
        try knowledge.saveMemoryItem(item)

        let output = try await store.memoryReview(
            goalID: nil,
            limit: 5,
            startSession: false
        )
        let payload = try parseJSON(output)

        #expect((payload["memory_items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["new_items"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("memoryReview excludes an item whose source has not arrived in the library")
    func memoryReviewExcludesDanglingMemoryAnchors() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let content = "An out-of-order memory anchor is not proof that canonical source text exists."
        let item = MemoryItem(
            id: "dangling-memory-item",
            kind: .concept,
            target: "Explain why source availability is authoritative",
            rubricJSON: #"{"criteria":["Requires a persisted library source"]}"#,
            sources: [
                MemoryItemSource(
                    id: "dangling-memory-anchor",
                    memoryItemID: "dangling-memory-item",
                    sourceID: "source-not-delivered-yet",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ],
            createdAt: old,
            updatedAt: old
        )
        try store.knowledgeStore().saveMemoryItem(item)
        // Reviewed and due again: only the missing source keeps it out.
        _ = try store.knowledgeStore().recordMemoryAttempt(
            MemoryAttempt(
                id: "dangling-memory-attempt",
                memoryItemID: item.id,
                attemptType: .review,
                prompt: "Why must the source exist?",
                learnerAnswer: "The text is what grounds the question.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old.addingTimeInterval(60)
            )
        )

        let payload = try parseJSON(
            try await store.memoryReview(goalID: nil, limit: 5, startSession: false)
        )
        #expect((payload["memory_items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["new_items"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("memoryReview keeps a multi-anchor item when one of its sources is hidden; hiding is visual only")
    func memoryReviewKeepsPartiallyHiddenMemoryItems() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let visible = "Visible canonical evidence for a relationship."
        let hidden = "Hidden canonical evidence for the same relationship."
        try insertSource(
            dbPath: dbPath,
            id: "visible-anchor-source",
            title: "Visible anchor",
            content: visible
        )
        try insertSource(
            dbPath: dbPath,
            id: "hidden-anchor-source",
            title: "Hidden anchor",
            content: hidden
        )
        try execSQL(
            dbPath: dbPath,
            "INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('hidden-anchor-source', 1)"
        )
        let old = Date().addingTimeInterval(-30 * 86_400)
        try store.knowledgeStore().saveMemoryItem(
            MemoryItem(
                id: "partially-hidden-memory-item",
                kind: .relationship,
                target: "Relate the visible and hidden evidence",
                rubricJSON: #"{"criteria":["Uses both sources"]}"#,
                sources: [
                    MemoryItemSource(
                        id: "visible-memory-anchor",
                        memoryItemID: "partially-hidden-memory-item",
                        sourceID: "visible-anchor-source",
                        excerpt: visible,
                        sourceSHA256: PaperContentPreparationService.sha256(visible),
                        sortIndex: 0
                    ),
                    MemoryItemSource(
                        id: "hidden-memory-anchor",
                        memoryItemID: "partially-hidden-memory-item",
                        sourceID: "hidden-anchor-source",
                        excerpt: hidden,
                        sourceSHA256: PaperContentPreparationService.sha256(hidden),
                        sortIndex: 1
                    ),
                ],
                createdAt: old,
                updatedAt: old
            )
        )
        _ = try store.knowledgeStore().recordMemoryAttempt(
            MemoryAttempt(
                id: "partially-hidden-memory-attempt",
                memoryItemID: "partially-hidden-memory-item",
                attemptType: .review,
                prompt: "How does the visible evidence bear on the hidden evidence?",
                learnerAnswer: "They describe one relationship from two sides.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old.addingTimeInterval(60)
            )
        )

        let payload = try parseJSON(
            try await store.memoryReview(goalID: nil, limit: 5, startSession: false)
        )
        // Hiding takes a source off the sources list and nowhere else
        // (product owner, 2026-09-11), so the item anchored on it is still due.
        let itemIDs = (payload["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String } ?? []
        #expect(itemIDs == ["partially-hidden-memory-item"])
    }

    @Test("endReviewSession turns a grounded first review into one durable memory trace across retries")
    func endReviewSessionCreatesFirstReviewMemoryTraceIdempotently() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval before feedback reveals what the learner can access and gives correction a specific error to update."
        try insertSource(
            dbPath: dbPath,
            id: "source-first-review",
            title: "Retrieval before feedback",
            content: content
        )
        let started = try await store.startReviewSession(
            topic: "First memory review",
            sourceID: "source-first-review"
        )
        let id = parsedSessionID(from: started)
        let transcript = "Tutor: Why retrieve before feedback?\nLearner: It exposes the gap that feedback should correct."
        let memoryAttempts: [[String: Any]] = [[
            "source_id": "source-first-review",
            "semantic_target": "Explain why feedback should follow an effortful retrieval attempt",
            "rubric": [
                "Retrieval exposes the learner's current access",
                "Feedback can then update a specific error or omission",
            ],
            "evidence_excerpt": content,
            "prompt": "Why should feedback come after you first try to retrieve the idea?",
            "learner_answer": "It exposes the gap that feedback should correct.",
            "evaluation": "Correct: the attempted retrieval diagnoses access and makes the correction specific.",
            "score": 0.82,
            "retrieval_quality": "independent",
            "missing_rubric_elements": ["Explicitly name current access"],
            "misconception": "Initially described feedback as useful without explaining the retrieval attempt.",
        ]]

        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.82,
            summary: "Connected effortful retrieval to targeted correction.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        let knowledge = try store.knowledgeStore()
        let items = try knowledge.loadMemoryItems()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.id == MemoryTutorIdentity.firstReviewItemID(
            portableSourceKey: try knowledge.portableMemorySourceKey(
                sourceID: "source-first-review"
            )
        ))
        #expect(item.kind == .concept)
        #expect(item.target == "Explain why feedback should follow an effortful retrieval attempt")
        #expect(item.rubricJSON == #"{"criteria":["Retrieval exposes the learner's current access","Feedback can then update a specific error or omission"]}"#)
        #expect(item.learnerContext == "Initially described feedback as useful without explaining the retrieval attempt.")
        #expect(item.sources.count == 1)
        #expect(item.sources.first?.sourceID == "source-first-review")
        #expect(item.sources.first?.excerpt == content)
        #expect(item.sources.first?.sourceSHA256 == PaperContentPreparationService.sha256(content))

        let attempts = try knowledge.loadMemoryAttempts(sessionID: id)
        let attempt = try #require(attempts.first)
        #expect(attempts.count == 1)
        #expect(attempt.id.hasPrefix("mcp-memory-attempt-"))
        #expect(attempt.memoryItemID == item.id)
        #expect(attempt.sessionID == id)
        #expect(attempt.exchangeID != nil)
        #expect(attempt.attemptType == .discovery)
        #expect(attempt.scheduleRating == .good)
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "completed")

        let itemCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items")
        let anchorCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_item_sources")
        let attemptCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts")
        let exchangeCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'")
        let schedule = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        )

        // The assistant may retry after its successful response was lost. The
        // app owns stable identities, so the identical call is a no-op rather
        // than a second curriculum item or scheduler advancement.
        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.82,
            summary: "Connected effortful retrieval to targeted correction.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == itemCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_item_sources") == anchorCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == attemptCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'") == exchangeCount)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        ) == schedule)
    }

    @Test("first-review Socratic retries share one curriculum item and replay exactly")
    func endReviewSessionCoalescesRepeatedFirstReviewAttempts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval before feedback reveals accessible knowledge, while the correction updates a specific omission."
        try insertSource(
            dbPath: dbPath,
            id: "repeated-intake-source",
            title: "Repeated intake",
            content: content
        )
        let started = try await store.startReviewSession(
            topic: "Repeated first review",
            sourceID: "repeated-intake-source"
        )
        let sessionID = parsedSessionID(from: started)
        let curriculum: [String: Any] = [
            "source_id": "repeated-intake-source",
            "semantic_target": "Explain why retrieval should precede feedback",
            "rubric": [
                "Retrieval reveals currently accessible knowledge",
                "Feedback updates a specific error or omission",
            ],
            "evidence_excerpt": content,
        ]
        var first = curriculum
        first.merge([
            "prompt": "Why try to retrieve before looking at feedback?",
            "learner_answer": "It makes memory stronger.",
            "evaluation": "That misses the diagnostic role of the attempt.",
            "score": 0.45,
            "retrieval_quality": "hinted",
            "missing_rubric_elements": ["Names currently accessible knowledge"],
            "misconception": "Treated retrieval only as strengthening.",
        ]) { _, new in new }
        var second = curriculum
        second.merge([
            "prompt": "What does the unaided attempt tell feedback to correct?",
            "learner_answer": "It exposes the exact omission, so feedback can update it.",
            "evaluation": "Correct; the retry now connects diagnosis to correction.",
            "score": 0.84,
            "retrieval_quality": "independent",
            "missing_rubric_elements": [] as [String],
            "misconception": "The strengthening-only misconception was corrected.",
        ]) { _, new in new }
        let attempts = [first, second]
        let transcript = "Tutor: Why retrieve first?\nLearner: It strengthens memory.\nTutor: What does it diagnose?\nLearner: The exact omission."

        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.84,
            summary: "Corrected the strengthening-only explanation.",
            transcript: transcript,
            memoryAttempts: attempts
        )
        let knowledge = try store.knowledgeStore()
        let item = try #require(try knowledge.loadMemoryItems().first)
        let storedAttempts = try knowledge.loadMemoryAttempts(sessionID: sessionID)
        #expect(try knowledge.loadMemoryItems().count == 1)
        #expect(storedAttempts.count == 2)
        #expect(Set(storedAttempts.map(\.memoryItemID)) == [item.id])
        #expect(storedAttempts.map(\.attemptType) == [.discovery, .review])
        #expect(item.learnerContext == "Treated retrieval only as strengthening.")

        let itemCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items")
        let attemptCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts")
        let exchangeCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(sessionID)'"
        )
        let schedule = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d', due_at, stability, repetition_count, lapse_count) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        )
        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.84,
            summary: "Corrected the strengthening-only explanation.",
            transcript: transcript,
            memoryAttempts: attempts
        )
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == itemCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == attemptCount)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(sessionID)'"
        ) == exchangeCount)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d', due_at, stability, repetition_count, lapse_count) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        ) == schedule)
    }

    @Test("endReviewSession rejects an ungrounded first review without partial writes")
    func endReviewSessionRejectsUngroundedFirstReview() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-first-review",
            title: "Canonical evidence",
            content: "Canonical text says retrieval should precede corrective feedback."
        )
        let started = try await store.startReviewSession(
            topic: "First memory review",
            sourceID: "source-first-review"
        )
        let id = parsedSessionID(from: started)

        #expect(throws: MCPError.self) {
            _ = try store.endReviewSession(
                sessionID: id,
                overallScore: 0.8,
                summary: "This must remain open.",
                transcript: "A review happened, but its evidence was invented.",
                memoryAttempts: [[
                    "source_id": "source-first-review",
                    "semantic_target": "Explain retrieval before feedback",
                    "rubric": ["Names effortful retrieval"],
                    "evidence_excerpt": "This plausible sentence does not occur anywhere in the canonical source.",
                    "prompt": "Why retrieve first?",
                    "learner_answer": "To reveal gaps.",
                    "evaluation": "Mostly correct.",
                    "score": 0.8,
                    "retrieval_quality": "independent",
                    "missing_rubric_elements": [] as [String],
                ]]
            )
        }
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "active")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_item_sources") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'") == 0)
    }

    @Test("endReviewSession leaves the review open when a memory attempt is malformed")
    func endReviewSessionRejectsMalformedMemoryAttempt() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "source-memory", title: "Memory", content: "Grounded source text.")
        let started = try await store.startReviewSession(topic: "Memory review", sourceID: "source-memory")
        let id = parsedSessionID(from: started)

        #expect(throws: MCPError.self) {
            _ = try store.endReviewSession(
                sessionID: id,
                overallScore: 0.8,
                summary: "Should not complete.",
                memoryAttempts: [[
                    "item_id": "invented-item",
                    "prompt": "Question",
                    "learner_answer": "Answer",
                    "evaluation": "Feedback",
                    "score": 0.8,
                    "retrieval_quality": "independent",
                    "missing_rubric_elements": [] as [String],
                ]]
            )
        }
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "active")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == 0)
    }

    @Test("endReviewSession stores exported chat transcript")
    func endReviewSessionStoresTranscript() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "AI for Bio fuzzy API problem drug discovery",
            content: "Drug discovery source content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(topic: "Please quiz me on AI for Bio fuzzy API problem drug discovery")
        let sessionID = started
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("Session ID: ") }?
            .components(separatedBy: "ID: ")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let ended = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.82,
            summary: "Understands the fuzzy API issue and needs more work on assays.",
            transcript: "Claude: What makes the API fuzzy?\nMe: The endpoints are underspecified."
        )
        let transcript = try store.getReviewSessionTranscript(sessionID: sessionID)
        let sessions = try store.getReviewSessions(topic: nil, sourceId: "source-a")

        #expect(ended.contains("Transcript exported to ForeverLM"))
        #expect(transcript.contains("Assistant: What makes the API fuzzy?"))
        #expect(transcript.contains("Learner: The endpoints are underspecified."))
        #expect(transcript.contains("Exported from an MCP review."))
        #expect(sessions.contains("1 exchanges"))
    }

    @Test("A session_id argument may be the chat link the app's Copy Link copies")
    func sessionIDArgumentAcceptsChatLink() throws {
        let id = "4B6E2C1A-0F3D-4E2B-9C8A-1D2E3F4A5B6C"
        #expect(MCPDataStore.reviewSessionID(from: id) == id)
        #expect(MCPDataStore.reviewSessionID(from: "  \(id)\n") == id)
        #expect(MCPDataStore.reviewSessionID(from: "foreverlm://chat/\(id)") == id)
        #expect(MCPDataStore.reviewSessionID(from: "\(ForeverLMRuntimeIdentity.urlScheme)://chat/\(id)") == id)
        #expect(MCPDataStore.reviewSessionID(from: "<foreverlm://chat/\(id)>") == id)
        #expect(MCPDataStore.reviewSessionID(from: "[Membrane potential](foreverlm://chat/\(id))") == id)
        // Other addresses are not sessions and pass through untouched, so the
        // not-found error names what was actually sent.
        #expect(MCPDataStore.reviewSessionID(from: "foreverlm://doc/\(id)") == "foreverlm://doc/\(id)")
        #expect(MCPDataStore.reviewSessionID(from: nil) == "")
        #expect(MCPDataStore.reviewSessionID(from: 42) == "")
    }

    @Test("getReviewSessionTranscript reads a chat by its copied link, mid-conversation")
    func transcriptByChatLink() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "source-a", title: "Membrane potential", content: "TMRM content.")

        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(topic: "Measuring mitochondrial membrane potential")
        let sessionID = started
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("Session ID: ") }?
            .components(separatedBy: "ID: ")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(!sessionID.isEmpty)

        // Still active: the link reads the session as it stands, not an export.
        let link = StudioEntityLink.chat(sessionID).markdownDestination
        let live = try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: link))
        #expect(live.contains("Review session: Measuring mitochondrial membrane potential"))
        #expect(live.contains("Status: active"))

        _ = try store.endReviewSession(
            sessionID: MCPDataStore.reviewSessionID(from: link),
            overallScore: 0.9,
            summary: "Knows TMRM in non-quench mode.",
            transcript: "Claude: Which dye?\nMe: TMRM, non-quench."
        )
        let done = try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: link))
        #expect(done.contains("Assistant: Which dye?"))
        #expect(done.contains("Learner: TMRM, non-quench."))
    }

    @Test("endReviewSession stores a role-labelled export as separate turns")
    func endReviewSessionStoresRoleLabelledTurns() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-role-turns",
            title: "Mitochondrial sodium",
            content: "Sodium and calcium alter mitochondrial metabolism."
        )
        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(
            topic: "Mitochondrial sodium",
            sourceID: "source-role-turns"
        )
        let sessionID = parsedSessionID(from: started)
        let exported = """
        Learner: Please quiz me on this week's reading.
        Assistant: Why can elevated sodium impair mitochondrial metabolism?
        Learner: I am not sure. Please explain it.
        Assistant: It removes calcium from mitochondria. Why can blocking that exchanger help?
        Learner: It keeps calcium-sensitive metabolism active.
        """

        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.7,
            summary: "Reviewed sodium handling.",
            transcript: exported
        )
        let exchanges = try store.knowledgeStore().loadReviewSessionExchanges(sessionID: sessionID)

        #expect(exchanges.count == 3)
        #expect(exchanges[0].question.isEmpty)
        #expect(exchanges[0].userAnswer == "Please quiz me on this week's reading.")
        #expect(exchanges[1].question == "Why can elevated sodium impair mitochondrial metabolism?")
        #expect(exchanges[1].userAnswer == "I am not sure. Please explain it.")
        #expect(exchanges[2].question == "It removes calcium from mitochondria. Why can blocking that exchanger help?")
        #expect(exchanges[2].userAnswer == "It keeps calcium-sensitive metabolism active.")
    }

    @Test("endReviewSession saves the review when the session id is unknown")
    func endReviewSessionSavesWhenSessionUnknown() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Mitochondrial energetics and aging",
            content: "Energy budgets and disease."
        )

        let store = MCPDataStore(dbPath: dbPath)
        // A session id that was never created (lost across a long chat, or another window).
        let ended = try store.endReviewSession(
            sessionID: "00000000-DEAD-BEEF-0000-000000000000",
            overallScore: 0.9,
            summary: "Strong on finite-budget logic; weaker on demand overshoot.",
            transcript: "Claude: Why isn't a hard cap enough?\nMe: Because demand can still overshoot it.",
            sourceIDs: ["source-a"],
            topic: "Mitochondrial energetics review"
        )

        // The review is preserved, not discarded, and linked to the source.
        #expect(ended.contains("was not found"))
        #expect(ended.contains("imported review"))
        let sessions = try store.getReviewSessions(topic: nil, sourceId: "source-a")
        #expect(sessions.contains("Mitochondrial energetics review"))
        #expect(sessions.contains("[completed]"))
        let transcript = try store.searchReviewSessions(queryText: "demand can still overshoot", limit: 5)
        #expect(transcript.contains("Mitochondrial energetics review"))
    }

    @Test("missing-session review recovery is idempotent after a lost response")
    func endReviewSessionRecoveryRetryDoesNotDuplicate() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "recovery-source",
            title: "Recovery source",
            content: "A recovered review must remain one durable transcript."
        )
        let arguments = (
            sessionID: "missing-provider-session",
            score: 0.84,
            summary: "Recovered exact review.",
            transcript: "Tutor: Why retrieve before feedback?\nLearner: It exposes what I can access.",
            topic: "Recovery review"
        )

        let first = try store.endReviewSession(
            sessionID: arguments.sessionID,
            overallScore: arguments.score,
            summary: arguments.summary,
            transcript: arguments.transcript,
            sourceIDs: ["recovery-source"],
            topic: arguments.topic
        )
        let sessionCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        )
        let exchangeCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges"
        )
        let scheduleCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'recovery-source'"
        )

        // Simulate a successful import whose tool response never reached the
        // caller. The exact replay resolves to the same content-addressed
        // recovery session and re-applies only idempotent Schedule completion.
        let second = try store.endReviewSession(
            sessionID: arguments.sessionID,
            overallScore: arguments.score,
            summary: arguments.summary,
            transcript: arguments.transcript,
            sourceIDs: ["recovery-source"],
            topic: arguments.topic
        )

        #expect(second == first)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        ) == sessionCount)
        #expect(sessionCount == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges") == exchangeCount)
        #expect(exchangeCount == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'recovery-source'"
        ) == scheduleCount)
        #expect(scheduleCount == 1)
    }

    @Test("missing-session recovery rolls back transcript and completion when Schedule fails")
    func endReviewSessionRecoveryRetriesAfterAtomicFailure() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "recovery-rollback-source",
            title: "Recovery rollback",
            content: "A failed Schedule write must not leave a completed transcript behind."
        )
        try execSQL(dbPath: dbPath, """
            CREATE TRIGGER fail_recovery_schedule
            BEFORE INSERT ON scheduled_sources
            BEGIN
                SELECT RAISE(ABORT, 'forced recovery Schedule failure');
            END;
        """)
        do {
            _ = try store.endReviewSession(
                sessionID: "missing-recovery-rollback",
                overallScore: 0.79,
                summary: "Recovered after a transactional failure.",
                transcript: "Tutor: Why atomic?\nLearner: Partial completion would consume review state.",
                sourceIDs: ["recovery-rollback-source"],
                topic: "Recovery rollback"
            )
            Issue.record("Expected the forced Schedule failure")
        } catch {
            #expect(error.localizedDescription.contains("forced recovery Schedule failure"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'active'"
        ) == 0)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions"
        ) == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources") == 0)

        try execSQL(dbPath: dbPath, "DROP TRIGGER fail_recovery_schedule")
        _ = try store.endReviewSession(
            sessionID: "missing-recovery-rollback",
            overallScore: 0.79,
            summary: "Recovered after a transactional failure.",
            transcript: "Tutor: Why atomic?\nLearner: Partial completion would consume review state.",
            sourceIDs: ["recovery-rollback-source"],
            topic: "Recovery rollback"
        )
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        ) == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources") == 1)
    }

    @Test("endReviewSession errors clearly when no session id and no transcript")
    func endReviewSessionErrorsWithNothingToSave() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)

        #expect(throws: MCPError.self) {
            _ = try store.endReviewSession(
                sessionID: "unknown-session",
                overallScore: 0.5,
                summary: "No transcript supplied."
            )
        }
    }

    @Test("transcript parser strips orphaned emphasis from bolded role labels")
    func parserStripsBoldRoleLabelEmphasis() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)

        // Claude/ChatGPT exports often bold the role label as "**Assistant:** …",
        // which used to leave a leading "** " glued to the message content.
        let turns = store.parseReviewTranscript(
            "**Assistant:** Q1. State the two premises.\n**You:** There is a finite energy budget."
        )

        #expect(turns.count == 1)
        #expect(turns.first?.question == "Q1. State the two premises.")
        #expect(turns.first?.answer == "There is a finite energy budget.")
    }
}

#endif
