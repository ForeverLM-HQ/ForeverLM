import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// Stopping paid work started over MCP (2026-09-27). What has to hold: every
/// tool call is listed while it runs and can be stopped by its id, and a stop
/// cancels the work, records who asked, and ends the entry; work a tool leaves
/// running registers the same way; the list and the stop never wait behind
/// the store gate; and every long paid tool tells the assistant how it is
/// stopped. The bulk re-queue half is in `BackgroundAISpendTests`.
@Suite("MCP running work")
struct MCPRunningWorkTests {

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? { lock.withLock { stored } }
        func set(_ value: String?) { lock.withLock { stored = value } }
    }

    private func waitForEntry(in work: MCPRunningWork) async -> MCPRunningWork.Entry? {
        for _ in 0..<300 {
            if let entry = work.snapshot.first { return entry }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: - The tools

    @Test("list_running_ai_work and cancel_ai_work are registered, off the store gate, and the list only reads")
    func toolsAreRegistered() {
        let names = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(names.isSuperset(of: MCPToolRegistry.runningWorkToolNames))
        // A stop that queued behind the writer it stops would be no stop.
        #expect(MCPToolRegistry.storeGateExemptToolNames.isSuperset(of: MCPToolRegistry.runningWorkToolNames))
        #expect(MCPToolRegistry.storeGateExemptToolNames.contains("cancel_source_audio_generation"))
        #expect(MCPToolRegistry.annotations(for: "list_running_ai_work")["readOnlyHint"] as? Bool == true)
        let cancel = MCPToolRegistry.annotations(for: "cancel_ai_work")
        #expect(cancel["readOnlyHint"] as? Bool == false)
        #expect(cancel["destructiveHint"] as? Bool == false)
        #expect(MCPToolRegistry.isToolAllowed("cancel_ai_work", scope: .full))
        #expect(!MCPToolRegistry.isToolAllowed("cancel_ai_work", scope: .ingest))
        let resume = MCPToolRegistry.annotations(for: "resume_ai_work")
        #expect(resume["readOnlyHint"] as? Bool == false)
        #expect(resume["destructiveHint"] as? Bool == false)
    }

    @Test("Every tool marked as spending money is a registered tool")
    func paidToolsAreRealTools() {
        let tools = MCPToolRegistry.shared.tools
        let names = Set(tools.map(\.name))
        for name in MCPToolRegistry.paidWorkToolNames {
            #expect(names.contains(name), "\(name) is marked as spending money but is not registered")
            let properties = tools.first { $0.name == name }?.inputSchema["properties"] as? [String: Any]
            #expect(properties?["approved_spend_usd"] != nil, "\(name) has no per-operation spend approval")
        }
    }

    @Test("The long paid tools tell the assistant how they are stopped")
    func longPaidToolsNameTheStop() {
        let byName = Dictionary(uniqueKeysWithValues: MCPToolRegistry.shared.tools.map { ($0.name, $0) })
        for name in [
            "generate_course_quizzes", "generate_course", "add_course_quiz_pictures", "generate_walkthrough",
            "generate_explainer_video", "import_teachable_course", "transcribe_meeting_recording",
            "run_scheduled_task_now", "decide_background_ai_job",
        ] {
            #expect(byName[name]?.description.contains("cancel_ai_work") == true, "\(name) does not say how it is stopped")
        }
    }

    @Test("A call is described by the first argument that names its subject")
    func aboutNamesTheSubject() {
        #expect(MCPRunningWork.about(["course_id": "course-1", "rewrite": true]) == "course_id course-1")
        #expect(MCPRunningWork.about(["source_ids": ["a", "b", "c"]]) == "3 source_ids")
        #expect(MCPRunningWork.about(["source_ids": ["a"]]) == "source_ids a")
        #expect(MCPRunningWork.about(["course_id": "  "]) == nil)
        #expect(MCPRunningWork.about(["rewrite": true]) == nil)
    }

    // MARK: - The registry

    @Test("A running call is listed under its own id, and a stop cancels it and says who asked")
    func stoppingACall() async throws {
        let work = MCPRunningWork()
        let seenID = Box()
        let call = Task {
            await work.run(toolCall: "generate_course_quizzes", about: "course_id course-1") { () -> Bool in
                seenID.set(MCPRunningWork.currentCallID)
                do {
                    try await Task.sleep(for: .seconds(30))
                    return false
                } catch {
                    return true
                }
            }
        }
        let listed = try #require(await waitForEntry(in: work))
        #expect(listed.kind == .toolCall)
        #expect(listed.tool == "generate_course_quizzes")
        #expect(listed.about == "course_id course-1")
        #expect(listed.stoppedBy == nil)

        let started = Date()
        #expect(work.stop(listed.id, by: .learner)?.id == listed.id)
        let (sawCancellation, stoppedBy) = await call.value
        #expect(sawCancellation, "the body never saw the stop")
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(stoppedBy == .learner)
        #expect(seenID.value == listed.id, "the body reads its own entry's id")
        #expect(work.snapshot.isEmpty)
        #expect(work.stop(listed.id, by: .assistant) == nil, "a finished call has nothing to stop")
        #expect(MCPRunningWork.currentCallID == nil)
    }

    @Test("A call its caller cancels ends too, without counting as a stop")
    func callerCancellationReachesTheCall() async throws {
        let work = MCPRunningWork()
        let call = Task {
            await work.run(toolCall: "generate_course", about: nil) { () -> Bool in
                (try? await Task.sleep(for: .seconds(30))) == nil
            }
        }
        _ = try #require(await waitForEntry(in: work))
        call.cancel()
        let (sawCancellation, stoppedBy) = await call.value
        #expect(sawCancellation)
        #expect(stoppedBy == nil)
        #expect(work.snapshot.isEmpty)
    }

    @Test("A paid call stops after its durable cost reaches the approved ceiling")
    func spendCeilingStopsCall() async throws {
        let work = MCPRunningWork()
        let call = Task {
            await work.run(
                toolCall: "add_course_quiz_pictures",
                about: "course_id course-1",
                spendLimitUSD: 3
            ) { () -> Bool in
                (try? await Task.sleep(for: .seconds(30))) == nil
            }
        }
        let listed = try #require(await waitForEntry(in: work))
        #expect(listed.spendLimitUSD == 3)
        work.recordSpend(2.75, for: listed.id)
        #expect(work.snapshot.first?.spentUSD == 2.75)
        #expect(work.snapshot.first?.stoppedBy == nil)

        work.recordSpend(0.25, for: listed.id)
        let (sawCancellation, stoppedBy) = await call.value
        #expect(sawCancellation)
        #expect(stoppedBy == .spendLimit)
        #expect(work.snapshot.isEmpty)
    }

    @Test("Background work is listed until it ends, and stopping it cancels it")
    func backgroundWork() async throws {
        let work = MCPRunningWork()
        let (ended, continuation) = AsyncStream<Bool>.makeStream()
        let seenID = Box()
        let id = work.startBackground(tool: "import_teachable_course", about: "transcripts of 3 lectures") {
            seenID.set(MCPRunningWork.currentCallID)
            let cancelled = (try? await Task.sleep(for: .seconds(30))) == nil
            continuation.yield(cancelled)
            continuation.finish()
        }
        #expect(work.snapshot.map(\.id) == [id])
        #expect(work.snapshot.first?.kind == .background)

        #expect(work.stop(id, by: .assistant)?.stoppedBy == .assistant)
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(seenID.value == id)
        for _ in 0..<300 where !work.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(work.snapshot.isEmpty)
    }

    // MARK: - Through the tools

    @Test("cancel_ai_work stops listed work by its work_id and names what was not running")
    func cancelThroughTheTools() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_running_work_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        let registry = MCPToolRegistry(store: store)

        let id = MCPRunningWork.shared.startBackground(tool: "import_teachable_course", about: "test \(UUID().uuidString)") {
            try? await Task.sleep(for: .seconds(30))
        }

        let listed = await registry.callToolDetailed(name: "list_running_ai_work", arguments: [:])
        #expect(!listed.isError, "\(listed.text)")
        let listJSON = try #require(try JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])
        let work = try #require(listJSON["work"] as? [[String: Any]])
        let mine = try #require(work.first { $0["work_id"] as? String == id })
        #expect(mine["kind"] as? String == "background")
        #expect(mine["tool"] as? String == "import_teachable_course")
        #expect(mine["spends_money"] as? Bool == true)
        // The list is not itself work.
        #expect(!work.contains { $0["tool"] as? String == "list_running_ai_work" })

        let refused = await registry.callToolDetailed(name: "cancel_ai_work", arguments: [:])
        #expect(refused.isError)

        let cancelled = await registry.callToolDetailed(name: "cancel_ai_work", arguments: ["work_ids": [id, "call-missing"]])
        #expect(!cancelled.isError, "\(cancelled.text)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(cancelled.text.utf8)) as? [String: Any])
        let stopped = try #require(json["stopped"] as? [[String: Any]])
        #expect(stopped.first { $0["work_id"] as? String == id }?["status"] as? String == "stopping")
        #expect(json["not_running"] as? [String] == ["call-missing"])

        for _ in 0..<300 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!MCPRunningWork.shared.snapshot.contains { $0.id == id })
    }

    @Test("A paid step of the app's own is listed, stopped by cancel_ai_work until resume_ai_work, and its request cancelled")
    func modelStepsThroughTheTools() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_running_work_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        let registry = MCPToolRegistry(store: store)
        // A registry of the test's own, its stops in memory: nothing reaches
        // this Mac's settings or another test's calls.
        let calls = AIInFlightCalls(stops: .memory())
        let step = "meeting_icon"

        try await AIInFlightCalls.$current.withValue(calls) {
            let id = try calls.begin(taskLabel: step, sourceTitle: "Lab meeting", subjectID: "meeting-7")
            let cancelled = CancelFlag()
            calls.attach(id) { cancelled.set() }

            let listed = await registry.callToolDetailed(name: "list_running_ai_work", arguments: [:])
            let listJSON = try #require(try JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])
            let work = try #require(listJSON["work"] as? [[String: Any]])
            let entry = try #require(work.first { $0["work_id"] as? String == "model-\(step)" })
            #expect(entry["kind"] as? String == "model_step")
            #expect(entry["task"] as? String == step)
            #expect(entry["about"] as? String == "Lab meeting")

            let stopped = await registry.callToolDetailed(name: "cancel_ai_work", arguments: ["work_ids": ["model-\(step)"]])
            #expect(!stopped.isError, "\(stopped.text)")
            #expect(cancelled.isSet)
            #expect(calls.isStopped(step))
            #expect(calls.end(id))

            let after = await registry.callToolDetailed(name: "list_running_ai_work", arguments: [:])
            let afterJSON = try #require(try JSONSerialization.jsonObject(with: Data(after.text.utf8)) as? [String: Any])
            let held = try #require(afterJSON["stopped_steps"] as? [[String: Any]])
            #expect(held.map { $0["task"] as? String } == [step])

            let refused = await registry.callToolDetailed(name: "resume_ai_work", arguments: [:])
            #expect(refused.isError)
            let resumed = await registry.callToolDetailed(name: "resume_ai_work", arguments: ["steps": [step, "paper_metadata"]])
            #expect(!resumed.isError, "\(resumed.text)")
            let resumedJSON = try #require(try JSONSerialization.jsonObject(with: Data(resumed.text.utf8)) as? [String: Any])
            #expect((resumedJSON["resumed"] as? [[String: Any]])?.map { $0["task"] as? String } == [step])
            #expect(resumedJSON["not_stopped"] as? [String] == ["paper_metadata"])
            #expect(!calls.isStopped(step))
        }
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

#endif
