import Foundation
import Observation
import ScreenCaptureKit

/// The meeting being recorded live on this Mac, one at a time.
///
/// Pressing Start files a meeting session at once, as any source is readable
/// the moment it is added: a session of the series its title names, under the
/// same `meeting://<series>/<title - date time>` address a Zoom caption file
/// gets. While the call runs, the Mac transcribes the call's sound and the
/// microphone on its own speech model and keeps each new slide of a window the
/// learner picked; the session's text is checkpointed as lines and slides
/// arrive, so a quit or a crash keeps what was heard. A chat holding the
/// session reads everything said so far each turn (`LiveMeetingChatContext`).
/// Stop writes the whole transcript and hands it to the meeting funnel every
/// other transcript goes through (`MeetingActionItemExtractor`).
///
/// Nothing here calls a model. (product owner, 2026-11-08: a live transcript
/// during a meeting, a chat on the side, and the slides on screen.)
@available(macOS 26.0, *)
@MainActor
@Observable
final class LiveMeetingController {
    static let shared = LiveMeetingController()

    enum Phase: Equatable {
        case idle
        /// Permission, the speech model (downloaded the first time) and the
        /// session row, before anything is heard.
        case starting
        case running
        case stopping
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var title = ""
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var sourceID: String?
    @ObservationIgnored private var groupID: String?
    private(set) var lines: [LiveMeetingLine] = []
    /// Words each voice is still saying, replaced as the model hears more.
    private(set) var hearing: [LiveMeetingVoice: String] = [:]
    private(set) var slides: [LiveMeetingSlide] = []
    private(set) var isWatchingSlides = false
    /// The last thing that went wrong, said in a line.
    var problem: String?

    @ObservationIgnored private weak var vm: StudioViewModel?
    @ObservationIgnored private var capture: LiveMeetingCapture?
    @ObservationIgnored private var updatesContinuation: AsyncStream<Event>.Continuation?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var linesSinceCheckpoint = 0
    @ObservationIgnored private var checkpointInFlight = false
    @ObservationIgnored private var checkpointPending = false

    private enum Event: Sendable {
        case line(LiveMeetingVoice, LiveMeetingTranscriber.Update)
        case slide(number: Int, shownAt: TimeInterval, imageURL: URL, text: String)
        case failure(String)
    }

    /// New lines before the session's text is checkpointed again; a slide
    /// checkpoints at once, so the chat can show it.
    static let linesPerCheckpoint = 12

    private init() {
        LiveMeetingChatContext.provider = { [weak self] sourceIDs in
            self?.chatContext(forSourceIDs: sourceIDs)
        }
    }

    var isActive: Bool { phase == .starting || phase == .running || phase == .stopping }

    // MARK: - Starting and stopping

    /// The meeting on the learner's calendar right now, to name the session
    /// after; nil when the calendar is not connected or holds none.
    static func suggestedTitle(now: Date = Date()) async -> String? {
        let service = AppleCalendarService.shared
        guard service.isConnected,
              let events = try? await service.shownEvents(
                  from: now.addingTimeInterval(-12 * 60 * 60),
                  to: now.addingTimeInterval(TimeInterval(MeetingCalendarEvent.graceMinutes * 60) + 60)
              ),
              let event = MeetingCalendarEvent.event(startingAt: now, title: "", in: events) else { return nil }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    func start(title rawTitle: String, vm: StudioViewModel) async {
        guard !isActive else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        reset()
        self.vm = vm
        self.title = title
        phase = .starting
        let startedAt = Date()
        self.startedAt = startedAt

        let article: StudioArticle
        let slidesFolder: URL
        do {
            article = try await Self.fileSession(title: title, startedAt: startedAt, storage: vm.storage)
            slidesFolder = try SlideFrameExtraction.prepareOutputDirectory(sourceID: article.id)
        } catch {
            fail("Couldn't start the meeting: \(error.localizedDescription)")
            return
        }
        sourceID = article.id
        groupID = article.parentGroup
        await vm.refreshArticles()

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        updatesContinuation = continuation
        updatesTask = Task { [weak self] in
            for await event in stream {
                self?.receive(event)
            }
        }
        do {
            capture = try await LiveMeetingCapture.start(
                locale: Locale.current,
                slidesFolder: slidesFolder,
                onLine: { voice, update in continuation.yield(.line(voice, update)) },
                onSlide: { number, shownAt, url, text in
                    continuation.yield(.slide(number: number, shownAt: shownAt, imageURL: url, text: text))
                },
                onFailure: { message in continuation.yield(.failure(message)) }
            )
        } catch {
            continuation.finish()
            updatesTask = nil
            // The session was filed for a meeting that never ran: nothing was
            // heard, so it goes again rather than leaving an empty row.
            try? await vm.storage.deleteSource(article.id)
            await vm.refreshArticles()
            sourceID = nil
            groupID = nil
            fail(error.localizedDescription)
            return
        }
        phase = .running
    }

    /// Starts keeping slides from what the learner picked in the system's
    /// window picker.
    func watchSlides(filter: SCContentFilter) async {
        guard phase == .running, let capture else { return }
        do {
            try await capture.watchSlides(filter: filter)
            isWatchingSlides = true
        } catch {
            problem = "Couldn't watch that window: \(error.localizedDescription)"
        }
    }

    func stopWatchingSlides() async {
        await capture?.stopWatchingSlides()
        isWatchingSlides = false
    }

    func stop() async {
        guard phase == .running, let capture else { return }
        phase = .stopping
        await capture.stop()
        self.capture = nil
        isWatchingSlides = false
        updatesContinuation?.finish()
        updatesContinuation = nil
        await updatesTask?.value
        updatesTask = nil
        hearing = [:]
        endedAt = Date()
        await saveFinal()
        phase = .finished
    }

    /// Leaves a finished meeting's pane for a new one.
    func clear() {
        guard phase == .finished || phase == .idle else { return }
        reset()
    }

    private func reset() {
        phase = .idle
        title = ""
        startedAt = nil
        endedAt = nil
        sourceID = nil
        groupID = nil
        lines = []
        hearing = [:]
        slides = []
        isWatchingSlides = false
        problem = nil
        linesSinceCheckpoint = 0
        checkpointPending = false
    }

    private func fail(_ message: String) {
        LiveMeetingLog.capture.error("live meeting: \(message, privacy: .public)")
        problem = message
        phase = .idle
        startedAt = nil
    }

    // MARK: - What the recorder hears

    private func receive(_ event: Event) {
        switch event {
        case .line(let voice, .volatile(let text)):
            hearing[voice] = text.isEmpty ? nil : text
        case .line(let voice, .final(let text, let start, let end)):
            hearing[voice] = nil
            let line = LiveMeetingLine(voice: voice, start: start, end: end, text: text)
            let recentThem = lines.suffix(40).filter { $0.voice == .them }
            if LiveMeetingTranscriptRules.isEcho(line, recentThem: Array(recentThem)) { return }
            insert(line)
            linesSinceCheckpoint += 1
            if linesSinceCheckpoint >= Self.linesPerCheckpoint { checkpoint() }
        case .slide(let number, let shownAt, let url, let text):
            slides.append(LiveMeetingSlide(number: number, shownAt: shownAt, imageURL: url, text: text))
            checkpoint()
        case .failure(let message):
            problem = message
        }
    }

    /// Lines arrive per voice, so one voice's line can land after a later
    /// line of the other; keep them in the order they were said.
    private func insert(_ line: LiveMeetingLine) {
        if let last = lines.last, last.start > line.start,
           let index = lines.lastIndex(where: { $0.start <= line.start }) {
            lines.insert(line, at: index + 1)
        } else if let last = lines.last, last.start > line.start {
            lines.insert(line, at: 0)
        } else {
            lines.append(line)
        }
    }

    // MARK: - The session's text

    private func checkpoint() {
        linesSinceCheckpoint = 0
        guard !checkpointInFlight else {
            checkpointPending = true
            return
        }
        checkpointInFlight = true
        Task {
            await writeContent(syncImmediately: false)
            checkpointInFlight = false
            if checkpointPending {
                checkpointPending = false
                checkpoint()
            }
        }
    }

    private func saveFinal() async {
        while checkpointInFlight { await Task.yield() }
        await writeContent(syncImmediately: true)
        guard let vm, let sourceID, let groupID else { return }
        let artifact = MeetingArtifact(
            id: SourceIdentity.stableID(for: "\(sourceID):live:transcript"),
            sourceId: sourceID,
            groupId: groupID,
            kind: .transcript,
            title: "\(title) Transcript",
            url: nil,
            localFilePath: nil,
            mimeType: "text/plain",
            modifiedAt: endedAt ?? Date(),
            sortIndex: 0
        )
        do {
            try await vm.storage.saveMeetingArtifact(artifact)
        } catch {
            problem = "Couldn't save the transcript: \(error.localizedDescription)"
        }
        if !lines.isEmpty {
            MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: sourceID)
        }
    }

    /// Writes the session's text through the same path a slide capture uses:
    /// the in-memory row first, then storage, so a rename the learner made in
    /// the meantime is kept.
    private func writeContent(syncImmediately: Bool) async {
        guard let vm, let sourceID, let startedAt,
              let index = vm.articles.firstIndex(where: { $0.id == sourceID }) else { return }
        let content = LiveMeetingSessionText.sessionContent(
            sessionTitle: vm.articles[index].title,
            lines: lines,
            slides: slides,
            startedAt: startedAt
        )
        vm.articles[index].content = content
        vm.articles[index].wordCount = content.split(separator: " ").count
        let article = vm.articles[index]
        do {
            try await vm.storage.saveSource(article, syncImmediately: syncImmediately)
        } catch {
            problem = "Couldn't save the meeting: \(error.localizedDescription)"
        }
    }

    /// Files the session: under the series the title names, made when there
    /// is none, with who was invited from the calendar.
    nonisolated static func fileSession(title: String, startedAt: Date, storage: StorageService) async throws -> StudioArticle {
        let groupID: String
        if let existing = try await storage.resolvedMeetingGroupID(matching: title) {
            groupID = existing
        } else {
            try await storage.saveMeetingGroup(name: title, metadata: MeetingMetadata(title: title))
            groupID = title
        }
        let sessionKey = StudioViewModel.readAISessionKey(title: title, date: startedAt, includeTime: true)
        let url = StudioViewModel.zoomLocalTranscriptSessionURL(groupID: groupID, sessionKey: sessionKey)
        var article = StudioArticle(
            url: url,
            title: sessionKey,
            sourceType: .meeting,
            discoveryOrigin: .localMeetings,
            parentGroup: groupID
        )
        article.domain = title
        article.dateAdded = startedAt
        article.content = "# \(sessionKey)\n\n## Transcript\n\n"
        article.wordCount = 0
        article.state = .ready
        let invited = await MeetingCalendarEvent.invitedNames(startedAt: startedAt, title: title)
        article.author = MeetingCalendarEvent.participantLine(invited)
        guard try await storage.insertSourceIfNew(&article) else {
            throw LiveMeetingError.captureFailed("A session of \(title) already starts this minute.")
        }
        return article
    }

    // MARK: - What a chat reads

    func chatContext(forSourceIDs sourceIDs: Set<String>) -> String? {
        guard let sourceID, sourceIDs.contains(sourceID), let startedAt else { return nil }
        return LiveMeetingSessionText.chatBlock(
            title: title,
            sourceID: sourceID,
            startedAt: startedAt,
            endedAt: endedAt,
            now: Date(),
            lines: lines,
            slides: slides,
            hearing: hearing
        )
    }

}

// MARK: - Opening the pane

extension StudioViewModel {
    /// Chat › Live Meeting and the Meetings list: the live meeting pane on
    /// screen. Already open, it comes to the front where it is; else it opens
    /// as a pane beside the one last clicked in, or, at the two panes the app
    /// arranges on its own, as a tab of that pane.
    func openLiveMeeting(in window: StudioWindowState? = nil) {
        let window = window ?? activeWindowState
        if window.isVoiceWorkspacePresented { window.isVoiceWorkspacePresented = false }
        if window.memoryReviewFocusYields(to: .liveMeeting) { leaveMemoryReviewFocus(in: window) }
        window.centerTabGroups = Self.layoutShowingLiveMeeting(window.centerTabGroups, focusedGroupID: window.focusedGroupID)
    }

    /// The arrangement once the live meeting pane is on screen. Pure.
    nonisolated static func layoutShowingLiveMeeting(
        _ layout: StudioCenterTabGroups,
        focusedGroupID: UUID?
    ) -> StudioCenterTabGroups {
        var layout = layout
        if let open = layout.groups.firstIndex(where: { $0.tabs.contains(.liveMeeting) }) {
            layout.groups[open].activeTab = .liveMeeting
            return layout
        }
        guard !layout.groups.isEmpty else { return layout }
        let focused = layout.groups.firstIndex { $0.id == focusedGroupID } ?? 0
        if layout.canCreateGroup {
            layout.groups.insert(.init(tabs: [.liveMeeting], activeTab: .liveMeeting), at: focused + 1)
        } else {
            layout.groups[focused].tabs.append(.liveMeeting)
            layout.groups[focused].activeTab = .liveMeeting
        }
        return layout
    }
}
