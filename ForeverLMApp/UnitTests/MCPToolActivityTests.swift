import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The popup a call from an AI app draws while it runs on ForeverLM's models
/// (docs/mcp-gateway.md, "What the learner sees while a call runs").
@Suite("Assistant work popup", .serialized)
@MainActor
struct MCPToolActivityTests {
    /// Delays long enough that no timer fires while a test runs: each test
    /// reveals and retires by hand.
    private func makeCenter() -> MCPToolActivityCenter {
        MCPToolActivityCenter(revealDelay: .seconds(3600), endedLinger: .seconds(3600), failedLinger: .seconds(3600), stopGrace: .seconds(3600))
    }

    private final class StopCount: @unchecked Sendable {
        var count = 0
    }

    @Test("A call that answers before the reveal delay never draws")
    func quickCallNeverDraws() {
        let center = makeCenter()
        let id = center.begin(assistant: "Codex", title: "Reading a figure", stop: nil)
        #expect(center.shown.isEmpty)
        center.end(id, failure: nil)
        center.reveal(id)
        #expect(center.shown.isEmpty)
    }

    @Test("A revealed call shows who asked and how far it got, then how it ended")
    func revealedCallShowsProgressThenEnd() throws {
        let center = makeCenter()
        let id = center.begin(assistant: "Codex", title: "Writing quizzes for Bioenergetics", stop: {})
        center.reveal(id)
        center.setDetail(id, "3 of 12 done")
        let running = try #require(center.shown.first)
        #expect(running.assistant == "Codex")
        #expect(running.title == "Writing quizzes for Bioenergetics")
        #expect(running.detail == "3 of 12 done")
        #expect(running.state == .running)
        #expect(running.canStop)

        center.end(id, failure: nil)
        #expect(center.shown.first?.state == .finished)
        #expect(center.shown.first?.detail == nil)
        // An ended call takes no more progress.
        center.setDetail(id, "12 of 12 done")
        #expect(center.shown.first?.detail == nil)

        center.retire(id)
        #expect(center.shown.isEmpty)
    }

    @Test("Reported detail is also visible to running-work status")
    func reportedDetailReachesRunningWork() async throws {
        let workID = MCPRunningWork.shared.startBackground(tool: "add_course_quiz_pictures", about: "course Bioenergetics") {
            try? await Task.sleep(for: .seconds(3600))
        }
        defer { _ = MCPRunningWork.shared.stop(workID, by: .assistant) }
        let center = makeCenter()
        let activityID = center.begin(assistant: "Codex", title: "Picturing the quizzes of Bioenergetics", stop: {})
        let reporter = MCPToolActivityReporter(id: activityID, callID: workID)

        await reporter.report("Choosing pictures · 3 of 12 quizzes")

        #expect(MCPRunningWork.shared.snapshot.first { $0.id == workID }?.detail == "Choosing pictures · 3 of 12 quizzes")
        center.retire(activityID)
    }

    @Test("Stop reaches the running call once, and the call reads as stopped however it answers")
    func stopReachesTheCallOnce() {
        let center = makeCenter()
        let stops = StopCount()
        let id = center.begin(assistant: nil, title: "Writing a course on Bioelectricity", stop: { stops.count += 1 })
        center.reveal(id)
        center.stop(id)
        center.stop(id)
        #expect(stops.count == 1)
        #expect(center.shown.first?.state == .stopping)

        center.end(id, failure: "Stopped by the learner in ForeverLM before generate_course finished.")
        #expect(center.shown.first?.state == .stopped)
    }

    @Test("A call the assistant stopped with cancel_ai_work reads as stopped, not failed")
    func assistantStopReadsAsStopped() {
        let center = makeCenter()
        let id = center.begin(assistant: "Codex", title: "Writing quizzes for Bioenergetics", stop: {})
        center.reveal(id)
        center.end(id, failure: "Stopped by cancel_ai_work before generate_course_quizzes finished.", stopped: true)
        #expect(center.shown.first?.state == .stopped)
    }

    @Test("A call with no running-work entry offers no Stop")
    func noEntryNoStop() {
        let center = makeCenter()
        let id = center.begin(assistant: "Claude", title: "Drawing an image", stop: nil)
        center.reveal(id)
        #expect(center.shown.first?.canStop == false)
        center.stop(id)
        #expect(center.shown.first?.state == .running)
    }

    @Test("Dismiss forgets an ended call; a running call stays listed, in the order the calls began")
    func dismissForgetsOnlyEndedCalls() {
        let center = makeCenter()
        let quizzes = center.begin(assistant: "Codex", title: "Picturing the quizzes of Bioenergetics", stop: {})
        let course = center.begin(assistant: "Claude", title: "Writing a course on Bioelectricity", stop: {})
        let image = center.begin(assistant: "Codex", title: "Drawing an image", stop: nil)
        for id in [quizzes, course, image] { center.reveal(id) }
        center.dismiss(course)
        #expect(center.shown.map(\.id) == [quizzes, course, image])

        center.end(image, failure: nil)
        center.dismiss(image)
        #expect(center.shown.map(\.id) == [quizzes, course])
    }

    @Test("A call still stopping after the grace may be hidden; before it, and while running, it stays")
    func overdueStopMayBeHidden() {
        let center = makeCenter()
        let id = center.begin(assistant: "Codex", title: "Writing quizzes for Bioenergetics", stop: {})
        center.reveal(id)
        center.markStopOverdue(id)
        #expect(center.shown.first?.stopIsOverdue == false, "a running call is never overdue")
        center.stop(id)
        center.dismiss(id)
        #expect(center.shown.map(\.id) == [id], "just stopped: still listed")
        center.markStopOverdue(id)
        #expect(center.shown.first?.stopIsOverdue == true)
        center.dismiss(id)
        #expect(center.shown.isEmpty)
        center.end(id, failure: nil)
        #expect(center.shown.isEmpty, "an answer after the hide brings nothing back")
    }

    @Test("The work chip says the one thing running in full, naming the app that asked")
    func workChipNamesTheOneCallRunning() throws {
        let center = makeCenter()
        let id = center.begin(assistant: "Codex", title: "Writing quizzes for Bioenergetics", stop: {})
        center.reveal(id)
        center.setDetail(id, "3 of 12 done")
        let item = StudioWorkItem(kind: .assistant(try #require(center.shown.first)))
        #expect(StudioWorkSummary([item]) == StudioWorkSummary(
            glyph: .spinner,
            title: "Codex is writing quizzes for Bioenergetics",
            status: "3 of 12 done"
        ))
        #expect(item.listTitle == "Writing quizzes for Bioenergetics")
        #expect(item.listCaption == "Codex · 3 of 12 done")

        center.end(id, failure: nil)
        let ended = StudioWorkItem(kind: .assistant(try #require(center.shown.first)))
        #expect(StudioWorkSummary([ended]) == StudioWorkSummary(
            glyph: .finished,
            title: "Writing quizzes for Bioenergetics",
            status: "Done"
        ))

        let anonymous = MCPToolActivityCenter.Activity(id: UUID(), assistant: nil, title: "Drawing an image", canStop: false)
        #expect(StudioWorkItem(kind: .assistant(anonymous)).chipTitle == "Drawing an image")
    }

    @Test("Several things running read as a count of what still runs, and nothing listed draws no chip")
    func workChipCountsWhatRuns() {
        let explainer = StudioWorkItem(kind: .explainer(.init(id: "source-1", title: "Mitochondria")))
        let importing = StudioWorkItem(kind: .courseImport("Importing “Thermodynamics”…"))
        let done = StudioWorkItem(kind: .assistant(MCPToolActivityCenter.Activity(
            id: UUID(), assistant: "Claude", title: "Drawing an image", state: .finished, canStop: false
        )))
        let failed = StudioWorkItem(kind: .assistant(MCPToolActivityCenter.Activity(
            id: UUID(), assistant: "Codex", title: "Writing a course on Bioelectricity", state: .failed("No credits left"), canStop: true
        )))

        #expect(StudioWorkSummary([explainer, importing, done])?.title == "2 things running")
        #expect(StudioWorkSummary([done, explainer]) == StudioWorkSummary(
            glyph: .spinner,
            title: "Writing an explainer of Mitochondria…",
            status: nil
        ))
        #expect(StudioWorkSummary([done, failed]) == StudioWorkSummary(
            glyph: .failed,
            title: "Writing a course on Bioelectricity",
            status: "No credits left"
        ))
        #expect(StudioWorkSummary([done, done])?.title == "2 done")
        #expect(StudioWorkSummary([]) == nil)
    }

    @Test("A failed call shows the first line of its error, without the Error: prefix")
    func failureShowsItsFirstLine() {
        let center = makeCenter()
        let id = center.begin(assistant: nil, title: "Writing quizzes for Bioenergetics", stop: {})
        center.reveal(id)
        center.end(id, failure: MCPToolActivityReporter.failureLine("Error: Course not found: bioenergetics.\nCall list_courses first."))
        #expect(center.shown.first?.state == .failed("Course not found: bioenergetics."))
        #expect(MCPToolActivityReporter.failureLine("Unknown tool: x") == "Unknown tool: x")
        #expect(MCPToolActivityReporter.failureLine("Error:") == "Failed")
    }

    @Test("Titles name what a tool works on, and a tool that only saves an app's own work has none")
    func titles() {
        let rewrite = MCPToolActivityTitle.forTool("generate_course_quizzes", arguments: ["rewrite": true])
        #expect(rewrite?.subject == .course)
        #expect(rewrite?.text(subjectName: "Bioenergetics") == "Rewriting quizzes for Bioenergetics")
        #expect(rewrite?.text(subjectName: "  ") == "Rewriting course quizzes")
        #expect(MCPToolActivityTitle.forTool("generate_course_quizzes", arguments: [:])?.text(subjectName: "Bioenergetics")
            == "Writing quizzes for Bioenergetics")
        #expect(MCPToolActivityTitle.forTool("generate_walkthrough", arguments: [:])?.subject == .source)
        #expect(MCPToolActivityTitle.forTool("find_lecture_papers", arguments: [:])?.subject == .lecture)

        for saved in ["save_course_quiz", "save_walkthrough", "save_animation", "save_image", "write_doc", "list_sources"] {
            #expect(MCPToolActivityTitle.forTool(saved, arguments: [:]) == nil, "\(saved)")
        }
        #expect(MCPToolActivityTitle.forTool("run_settings_action", arguments: ["action": "sync_icloud_now"]) == nil)
        #expect(MCPToolActivityTitle.forTool("run_settings_action", arguments: ["action": "prepare_memory_review_now"]) != nil)
    }

    @Test("Every tool that spends money either draws the popup or says why it does not")
    func everyPaidToolIsDecided() {
        let shown = MCPToolActivityTitle.shownToolNames
        let notShown = MCPToolActivityTitle.notShownPaidToolNames
        #expect(shown.isDisjoint(with: notShown))
        #expect(shown.union(notShown) == MCPToolRegistry.paidWorkToolNames)
        for name in shown {
            let arguments: [String: Any] = name == "run_settings_action" ? ["action": "prepare_memory_review_now"] : [:]
            #expect(MCPToolActivityTitle.forTool(name, arguments: arguments) != nil, "\(name)")
        }
        for name in notShown {
            #expect(MCPToolActivityTitle.forTool(name, arguments: [:]) == nil, "\(name)")
        }
    }

    @Test("Only a call from outside the app opens the popup, named for the app that made it")
    func onlyExternalCallsOpenThePopup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let arguments: [String: Any] = ["topic": "Bioelectricity"]

        #expect(await store.beginToolActivity(name: "generate_course", arguments: arguments, access: .internalFullAccess) == nil)

        let codex = MCPAccessContext(clientID: "chatgpt-directory", scope: .full, connectorLabel: "ChatGPT", assistantName: "Codex")
        #expect(await store.beginToolActivity(name: "save_course_quiz", arguments: arguments, access: codex) == nil)

        let reporter = try #require(await store.beginToolActivity(name: "generate_course", arguments: arguments, access: codex))
        let shared = MCPToolActivityCenter.shared
        shared.reveal(reporter.id)
        let shown = try #require(shared.shown.first { $0.id == reporter.id })
        #expect(shown.title == "Writing a course on Bioelectricity")
        #expect(shown.assistant == "Codex")
        // Outside a running-work call there is nothing to stop it through.
        #expect(!shown.canStop)
        shared.retire(reporter.id)
    }
}

#endif
