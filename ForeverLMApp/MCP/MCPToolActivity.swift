#if os(macOS)
import Combine
import Foundation

// MARK: - What an AI app set ForeverLM's models to do, on screen (2026-09-27)
//
// The product owner: when Claude, Codex or another AI app calls a tool that starts a lot
// of work in ForeverLM on ForeverLM's own models, the app shows it in a popup —
// "regenerating materials for the bioenergetics course". Not when the app does
// the work itself and only uploads what it came up with: `save_course_quiz`,
// `save_walkthrough` and the like spend nothing here and show nothing.
//
// Since 2026-10-06 the popup is a line of the Studio window's one work chip,
// which every background job shares, and since 2026-10-13 that chip is an
// icon in the strip with the asking app's logo (`StudioWorkButton`): "Codex
// is writing quizzes for Bioenergetics · 3 of 12" is its tooltip while it
// is the only thing running, and a row of the icon's list with how far it
// has got and Stop — which stops the call through `MCPRunningWork`, exactly
// as `cancel_ai_work` would, so the assistant is told the learner stopped
// it. A running call is never hidden: the chip is the tucked form the
// popup's chevron used to fold it into ("not get rid of it; just temp
// hide", the product owner, 2026-09-27). A call that answers within `revealDelay`
// never draws: a figure already read or a course with nothing left to
// write is not worth a flash on screen.
//
// Only calls from outside the app count. The in-app chat already draws each
// tool call as a row of its own, and Settings and scheduled tasks are the
// app's own doing. docs/mcp-gateway.md ("What the learner sees while a call
// runs") is the record.

/// The popups for calls AI apps made, one per call, in the order they began.
@MainActor
final class MCPToolActivityCenter: ObservableObject {
    static let shared = MCPToolActivityCenter()

    struct Activity: Identifiable, Equatable {
        enum State: Equatable {
            case running
            /// Stop was pressed; the call ends at its next suspension.
            case stopping
            case finished
            case stopped
            case failed(String)
        }

        let id: UUID
        /// The app that asked, as it registered itself; nil when it gave no name.
        let assistant: String?
        var title: String
        /// How far the call has got ("3 of 12", "Writing module 2 of 5").
        var detail: String?
        var state: State = .running
        /// False when the call has no running-work entry to stop it through.
        let canStop: Bool
        /// Stop was pressed `stopGrace` ago and the call still has not
        /// answered (a tool that never reaches a cancellation point): the
        /// chip's row may then be hidden, though the call is not over.
        var stopIsOverdue = false

        var hasEnded: Bool {
            switch state {
            case .running, .stopping: return false
            case .finished, .stopped, .failed: return true
            }
        }
    }

    /// What the windows' work chip lists: calls past `revealDelay`, and for a
    /// few seconds after one ends, how it ended.
    @Published private(set) var shown: [Activity] = []

    private struct Entry {
        var activity: Activity
        var revealed = false
        let stop: (@Sendable () -> Void)?
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let revealDelay: Duration
    private let endedLinger: Duration
    private let failedLinger: Duration
    private let stopGrace: Duration

    init(
        revealDelay: Duration = .seconds(2),
        endedLinger: Duration = .seconds(4),
        failedLinger: Duration = .seconds(10),
        stopGrace: Duration = .seconds(15)
    ) {
        self.revealDelay = revealDelay
        self.endedLinger = endedLinger
        self.failedLinger = failedLinger
        self.stopGrace = stopGrace
    }

    /// Starts tracking a call. It draws once it has run for `revealDelay`.
    func begin(assistant: String?, title: String, stop: (@Sendable () -> Void)?) -> UUID {
        let id = UUID()
        entries[id] = Entry(
            activity: Activity(id: id, assistant: assistant, title: title, canStop: stop != nil),
            stop: stop
        )
        order.append(id)
        let delay = revealDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.reveal(id)
        }
        return id
    }

    func setTitle(_ id: UUID, _ title: String) {
        guard var entry = entries[id], !entry.activity.hasEnded else { return }
        entry.activity.title = title
        entries[id] = entry
        publish()
    }

    func setDetail(_ id: UUID, _ detail: String?) {
        guard var entry = entries[id], !entry.activity.hasEnded else { return }
        entry.activity.detail = detail
        entries[id] = entry
        publish()
    }

    /// The call answered. `failure` is its error, nil when it succeeded. A
    /// call stopped from here or by `cancel_ai_work` (`stopped`) reads as
    /// stopped however it answered.
    func end(_ id: UUID, failure: String?, stopped: Bool = false) {
        guard var entry = entries[id], !entry.activity.hasEnded else { return }
        let wasStopped = stopped || entry.activity.state == .stopping
        entry.activity.state = wasStopped ? .stopped : failure.map(Activity.State.failed) ?? .finished
        entry.activity.detail = nil
        guard entry.revealed else {
            retire(id)
            return
        }
        entries[id] = entry
        publish()
        let linger = failure != nil && !wasStopped ? failedLinger : endedLinger
        Task { [weak self] in
            try? await Task.sleep(for: linger)
            self?.retire(id)
        }
    }

    /// The learner pressed Stop.
    func stop(_ id: UUID) {
        guard var entry = entries[id], entry.activity.state == .running, let stop = entry.stop else { return }
        entry.activity.state = .stopping
        entries[id] = entry
        publish()
        stop()
        let grace = stopGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.markStopOverdue(id)
        }
    }

    /// A call still stopping `stopGrace` after Stop may be hidden from the
    /// chip (`dismiss`). `stop` schedules it; tests call it directly.
    func markStopOverdue(_ id: UUID) {
        guard var entry = entries[id], entry.activity.state == .stopping, !entry.activity.stopIsOverdue else { return }
        entry.activity.stopIsOverdue = true
        entries[id] = entry
        publish()
    }

    /// The learner dismissed an ended call from the chip's list before it
    /// left on its own, or hid one that has not answered `stopGrace` after
    /// Stop. A running call has no dismiss: it stays listed until it ends.
    func dismiss(_ id: UUID) {
        guard let entry = entries[id], entry.activity.hasEnded || entry.activity.stopIsOverdue else { return }
        retire(id)
    }

    /// Draws a call that is still running. `begin` schedules it; tests call it
    /// directly rather than wait.
    func reveal(_ id: UUID) {
        guard var entry = entries[id], !entry.revealed, !entry.activity.hasEnded else { return }
        entry.revealed = true
        entries[id] = entry
        publish()
    }

    /// Forgets a call. `end` schedules it; tests call it directly.
    func retire(_ id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        publish()
    }

    private func publish() {
        let nextShown = order.compactMap { entries[$0] }.filter(\.revealed).map(\.activity)
        if nextShown != shown { shown = nextShown }
    }
}

/// A running call's handle on its popup, for a handler that knows more than
/// its tool's name: the course it resolved, how far it has got. Nil outside a
/// call that has a popup, so a handler reports unconditionally through
/// `MCPToolActivityReporter.current?` and every other caller stays quiet.
struct MCPToolActivityReporter: Sendable {
    @TaskLocal static var current: MCPToolActivityReporter?

    let id: UUID
    /// The call's `MCPRunningWork` entry, when it has one.
    var callID: String? = nil

    func report(_ detail: String?) async {
        if let callID { MCPRunningWork.shared.setDetail(callID, detail) }
        await MainActor.run { MCPToolActivityCenter.shared.setDetail(id, detail) }
    }

    /// For a progress callback that already runs on the main actor.
    @MainActor
    func reportNow(_ detail: String?) {
        if let callID { MCPRunningWork.shared.setDetail(callID, detail) }
        MCPToolActivityCenter.shared.setDetail(id, detail)
    }

    func retitle(_ title: String) async {
        await MainActor.run { MCPToolActivityCenter.shared.setTitle(id, title) }
    }

    func end(_ outcome: MCPToolRegistry.ToolCallOutcome) async {
        let failure = outcome.isError ? Self.failureLine(outcome.text) : nil
        // Still listed: the entry goes when the call's task returns, after this.
        let stopped = callID.map { callID in
            MCPRunningWork.shared.snapshot.contains { $0.id == callID && $0.stoppedBy != nil }
        } ?? false
        await MainActor.run { MCPToolActivityCenter.shared.end(id, failure: failure, stopped: stopped) }
    }

    /// A failed call's first line without the "Error: " every tool answer
    /// starts with; the rest of the answer is written for the assistant.
    static func failureLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let line = first.hasPrefix("Error:") ? String(first.dropFirst("Error:".count)) : first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Failed" : trimmed
    }
}

/// What a popup says a tool is doing, and which of its arguments names what
/// it does it to.
struct MCPToolActivityTitle: Equatable {
    enum Subject: Equatable {
        case course, lecture, source, topic, notebook
        /// A mnemonic reading's subject: its book, its first source, the
        /// reading written into, or its Notebook.
        case reading
    }

    let subject: Subject?
    /// Followed by the subject's name: "Writing quizzes for" Bioenergetics.
    let named: String
    /// When there is no name to give.
    let unnamed: String

    private init(_ subject: Subject?, _ named: String, _ unnamed: String) {
        self.subject = subject
        self.named = named
        self.unnamed = unnamed
    }

    private init(_ text: String) {
        self.init(nil, text, text)
    }

    func text(subjectName: String?) -> String {
        guard let name = subjectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return unnamed }
        return "\(named) \(name)"
    }

    /// The popup for a tool that sets ForeverLM's models to work, or nil for
    /// one that does not draw it. Every tool in
    /// `MCPToolRegistry.paidWorkToolNames` is either here or in
    /// `notShownPaidToolNames`, which `MCPToolActivityTests` checks.
    static func forTool(_ name: String, arguments: [String: Any]) -> MCPToolActivityTitle? {
        switch name {
        case "generate_course_quizzes":
            return arguments["rewrite"] as? Bool == true
                ? Self(.course, "Rewriting quizzes for", "Rewriting course quizzes")
                : Self(.course, "Writing quizzes for", "Writing course quizzes")
        case "add_course_quiz_pictures":
            return Self(.course, "Picturing the quizzes of", "Picturing course quizzes")
        case "add_textbook_to_course":
            return Self(.course, "Choosing textbook readings for", "Choosing textbook readings")
        case "generate_course":
            return Self(.topic, "Writing a course on", "Writing a course")
        case "make_article_reading_view":
            return Self(.source, "Making a reading view of", "Making a reading view")
        case "generate_walkthrough":
            return Self(.source, "Writing a walkthrough of", "Writing a walkthrough")
        case "generate_explainer":
            return Self(.source, "Writing an explainer of", "Writing an explainer")
        case "generate_audio_overview":
            return Self(.notebook, "Writing an audio overview of", "Writing an audio overview")
        case "generate_report":
            return Self(.notebook, "Writing a report for", "Writing a report")
        case "draft_cards":
            return Self(.notebook, "Drafting cards for", "Drafting cards")
        case "make_cards_from_canvas":
            return Self("Drafting cards from the Canvas")
        case "generate_mnemonic_reading":
            return Self(.reading, "Writing questions for", "Writing a mnemonic reading")
        case "ask_canvas":
            switch arguments["tool"] as? String {
            case "connect": return Self("Connecting cards on the Canvas")
            case "gaps": return Self("Finding the gaps between cards on the Canvas")
            default: return Self("Bridging cards on the Canvas")
            }
        case "get_source_levels":
            return arguments["write_if_missing"] as? Bool == true
                ? Self(.source, "Zooming out on", "Writing a source's reading levels")
                : Self(.source, "Reading the levels of", "Reading a source's levels")
        case "generate_image":
            return Self("Drawing an image")
        case "inspect_paper_figure":
            return Self(.source, "Reading a figure in", "Reading a figure")
        case "transcribe_meeting_recording":
            return Self(.source, "Transcribing", "Transcribing a meeting")
        case "scan_video_for_cited_papers":
            return Self(.source, "Finding the papers cited in", "Finding cited papers")
        case "scan_meeting_for_mentioned_papers":
            return Self(.source, "Finding the papers mentioned in", "Finding mentioned papers")
        case "scan_article_for_linked_sources":
            return Self(.source, "Finding the sources linked from", "Finding linked sources")
        case "discover_sources":
            return Self("Searching the web for sources")
        case "find_podcast_on_youtube":
            return Self(.source, "Looking on YouTube for", "Looking on YouTube for an episode")
        case "find_lecture_papers":
            return Self(.lecture, "Finding the papers of", "Finding a lecture's papers")
        case "ingest_lecture_papers":
            return Self(.lecture, "Importing the papers of", "Importing a lecture's papers")
        case "download_papers_needing_attention":
            return Self("Downloading papers")
        case "recheck_paywalled_papers":
            return Self("Rechecking paywalled papers")
        case "make_atlas":
            return Self(.topic, "Laying out an Atlas of", "Laying out an Atlas")
        case "get_atlas":
            // A read answers before the popup would show; a deepening is
            // one model call.
            return arguments["deepen"] as? Bool == true ? Self("Writing an Atlas concept in depth") : Self("Reading an Atlas")
        case "run_settings_action":
            switch arguments["action"] as? String {
            case "prepare_memory_review_now": return Self("Preparing the memory review")
            case "draw_missing_meeting_icons": return Self("Drawing meeting icons")
            // The rest are syncs and resets, which run no model.
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The tools `forTool` draws a popup for.
    static let shownToolNames: Set<String> = [
        "generate_course_quizzes", "add_course_quiz_pictures", "add_textbook_to_course",
        "generate_course", "generate_walkthrough", "generate_explainer", "generate_audio_overview", "generate_report", "generate_image",
        "draft_cards", "generate_mnemonic_reading", "ask_canvas",
        "get_source_levels",
        "make_cards_from_canvas",
        "inspect_paper_figure", "transcribe_meeting_recording",
        "scan_video_for_cited_papers", "scan_meeting_for_mentioned_papers", "scan_article_for_linked_sources",
        "discover_sources", "make_article_reading_view",
        "find_podcast_on_youtube",
        "find_lecture_papers", "ingest_lecture_papers",
        "download_papers_needing_attention", "recheck_paywalled_papers",
        "run_settings_action",
        "make_atlas", "get_atlas",
    ]

    /// Paid work that draws no popup, and why.
    static let notShownPaidToolNames: Set<String> = [
        // Their work shows where it lives already: the price dialog and the
        // Videos row, the sidebar's audio panel, and a Teachable course's
        // banner and fetching rows (whose transcripts run after the call
        // answers).
        "generate_explainer_video", "generate_source_audio",
        "import_teachable_course", "fetch_video_transcript",
        // The episode turns readable in the Reader when the call answers, and
        // its formatting runs after it.
        "import_podcast_youtube_transcript",
        // One paper's or page's metadata read: seconds. An assistant filing a
        // reading list makes these one after another, and a popup per paper
        // would only flicker.
        "extract_paper_metadata", "extract_article_metadata",
        "import_paper_from_url", "import_local_pdf_as_paper",
        "import_connector_paper", "import_video_cited_paper",
        // A paper's metadata read, or a book that shows its progress in the
        // Books list the way Add Book's does.
        "import_local_file",
    ]
}

extension MCPDataStore {
    /// Opens the popup for a call an AI app made to a tool that sets
    /// ForeverLM's models to work, and returns its reporter; nil for every
    /// other call. Runs inside the call's store gate, which covers the name
    /// lookups.
    func beginToolActivity(
        name: String,
        arguments: [String: Any],
        access: MCPAccessContext
    ) async -> MCPToolActivityReporter? {
        guard access.clientID != MCPAccessContext.internalFullAccess.clientID,
              let title = MCPToolActivityTitle.forTool(name, arguments: arguments) else { return nil }
        let subjectName: String?
        if let subject = title.subject {
            subjectName = await toolActivitySubjectName(subject, arguments: arguments)
        } else {
            subjectName = nil
        }
        let text = title.text(subjectName: subjectName)
        let assistant = access.assistantName
        let callID = MCPRunningWork.currentCallID
        let stop = Self.learnerStop(callID: callID)
        let id = await MainActor.run {
            MCPToolActivityCenter.shared.begin(assistant: assistant, title: text, stop: stop)
        }
        return MCPToolActivityReporter(id: id, callID: callID)
    }

    /// Stop goes through the call's running-work entry, as `cancel_ai_work`
    /// does, so the assistant's answer says the learner stopped it.
    private static func learnerStop(callID: String?) -> (@Sendable () -> Void)? {
        guard let callID else { return nil }
        return { _ = MCPRunningWork.shared.stop(callID, by: .learner) }
    }

    /// The name of what a call works on, read the way its tool reads it. Nil
    /// when the argument is missing or names nothing; the tool then fails on
    /// its own terms and the popup says what it was doing without a name.
    /// Read through the storage actor: this runs for the long paid tools that
    /// hold no store gate, so it never reads the cached connection.
    func toolActivitySubjectName(_ subject: MCPToolActivityTitle.Subject, arguments: [String: Any]) async -> String? {
        func argument(_ key: String) -> String? {
            guard let text = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        let storage = notebookFileStorage
        switch subject {
        case .topic:
            return argument("topic")
        case .course:
            guard let input = argument("course_id"),
                  let courseID = try? await resolveExistingCourseID(input: input, storage: storage) else { return nil }
            // A course from before titles were stored is named by its id.
            let title = (try? await storage.loadCourseMetadata())?[courseID]?.title
            return title ?? courseID
        case .lecture:
            guard let lectureID = argument("lecture_id"),
                  let lecture = (try? await storage.loadCourseLectures())?.first(where: { $0.id == lectureID }) else { return nil }
            return lecture.title ?? "Lecture \(lecture.number)"
        case .source:
            guard let sourceID = argument("source_id"),
                  let source = try? await storage.loadSourceWithoutContent(sourceID) else { return nil }
            return source.title
        case .notebook:
            guard let notebookID = argument("notebook_id"),
                  let notebook = try? await storage.loadLearningGoal(notebookID), notebook.isNotebook else { return nil }
            return notebook.title
        case .reading:
            if let book = argument("book") {
                return (try? await storage.bookChapters(named: book))?.title ?? book
            }
            if let first = (arguments["source_ids"] as? [String])?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }),
               let source = try? await storage.loadSourceWithoutContent(first) {
                return source.title
            }
            if let readingID = argument("reading_id"),
               let reading = try? await storage.loadArtifact(readingID) {
                return reading.title
            }
            guard let notebookID = argument("notebook_id"),
                  let notebook = try? await storage.loadLearningGoal(notebookID), notebook.isNotebook else { return nil }
            return notebook.title
        }
    }
}

#endif
