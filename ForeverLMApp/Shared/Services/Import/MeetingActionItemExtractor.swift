import Foundation
import OSLog

/// Reads the action items out of a meeting session the moment its transcript
/// is in the library (planner-design.md, "A meeting series on the clock").
///
/// One funnel for the five ways a transcript lands — the Zoom folder
/// watcher, a Zoom cloud recording, the Mac's own transcription, a Drive or
/// folder import, and an MCP attach — each of which calls
/// `noteTranscriptReady` after its write. The extractor decides: only a
/// session of a series with a schedule is read, only once per session (the durable check is the rows themselves;
/// an empty result is remembered for the process so a transcript with no
/// asks is not re-read on every import), and the model is
/// `AITask.meetingActionItems` from Settings. Ids are the app's
/// (`MeetingActionItem.makeID`), so a slow or repeated call can never
/// reshuffle what the learner ticked.
actor MeetingActionItemExtractor {
    static let shared = MeetingActionItemExtractor()

    private let logger = Logger(subsystem: "ForeverLM", category: "MeetingActionItems")
    private let storage: StorageService
    private var inFlight: Set<String> = []
    private var readWithoutItems: Set<String> = []

    init(storage: StorageService = StorageService()) {
        self.storage = storage
    }

    /// A meeting session's transcript is stored. Cheap to call for any
    /// session; returns at once when there is nothing to do. The session is
    /// folded into the sitting it continues, if it continues one, first; the
    /// action items — a model call — after, read from whichever session
    /// survived.
    nonisolated func noteTranscriptReady(sourceID: String) {
        Task {
            await self.handleTranscriptReady(sourceID: sourceID)
        }
    }

    /// The funnel's body, awaitable so a test can drive it against its own
    /// store. Returns the merge it performed, if any.
    @discardableResult
    func handleTranscriptReady(sourceID: String) async -> MeetingSessionMergeOutcome? {
        // One sitting, one session: a second Zoom call of the same standup
        // becomes part of the first (KnowledgeStore+MeetingSessionMerge).
        var merged: MeetingSessionMergeOutcome?
        do {
            merged = try await storage.absorbMeetingSessionContinuation(sourceID: sourceID)
        } catch {
            logger.error("Folding meeting session \(sourceID, privacy: .public) into its sitting failed: \(error.localizedDescription, privacy: .public)")
        }
        if let merged {
            logger.info("Meeting session \(sourceID, privacy: .public) is part of \(merged.survivorID, privacy: .public) (\(merged.absorbedIDs.count) part(s) folded)")
            // The library changed under every open window: the sidebar drops
            // the absorbed row and the survivor's reader shows the whole
            // sitting. Same signal every mutating MCP tool sends.
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
            readWithoutItems.remove(merged.survivorID)
            await extract(sourceID: merged.survivorID, force: true)
        } else {
            await extract(sourceID: sourceID)
        }
        return merged
    }

    /// Sessions were folded by hand (the series' menu, `merge_meeting_sessions`):
    /// the survivor's transcript is new, so its items are read again.
    nonisolated func noteSessionsMerged(survivorID: String) {
        Task {
            await self.rereadAfterMerge(survivorID: survivorID)
        }
    }

    func rereadAfterMerge(survivorID: String) async {
        readWithoutItems.remove(survivorID)
        await extract(sourceID: survivorID, force: true)
    }

    /// Reads one session. Returns the items written, or nil when the session
    /// was skipped (not a scheduled series, already read, no transcript).
    @discardableResult
    func extract(sourceID: String, force: Bool = false) async -> [MeetingActionItem]? {
        guard !inFlight.contains(sourceID) else { return nil }
        if !force, readWithoutItems.contains(sourceID) { return nil }
        inFlight.insert(sourceID)
        defer { inFlight.remove(sourceID) }
        do {
            guard let article = try await storage.loadSourceWithoutContent(sourceID),
                  article.sourceType == .meeting, article.state == .ready,
                  let rawGroupID = article.parentGroup else { return nil }
            let groupID = try await storage.canonicalMeetingGroupID(rawGroupID)
            let scheduled = try await storage.scheduledMeetingGroups()
            guard let series = scheduled.first(where: { $0.id == groupID }) else { return nil }
            if !force, try await storage.hasMeetingActionItems(sourceID: sourceID) { return nil }
            guard let content = await storage.loadSourceContent(sourceID) else { return nil }
            // A Zoom cloud session stores the bare transcript; a merged
            // session has it under its "## Transcript" heading.
            let hasSections = MeetingArtifactKind.allCases.contains { MeetingContent.contains(section: $0, in: content) }
            guard let transcript = MeetingContent.text(for: .transcript, in: content) ?? (hasSections ? nil : content) else { return nil }
            guard let config = KeychainService.resolveConfig(for: .meetingActionItems) else {
                logger.notice("Meeting action items for \(sourceID, privacy: .public) skipped: no model route")
                return nil
            }
            let drafts = try await AIService().extractMeetingActionItems(
                seriesTitle: series.title,
                sessionTitle: article.title,
                transcript: transcript,
                config: config
            )
            let now = Date()
            let items = drafts.enumerated().map { index, draft in
                MeetingActionItem(
                    groupID: groupID,
                    sourceID: sourceID,
                    position: index + 1,
                    text: draft.text,
                    owner: draft.owner,
                    dueHint: draft.due,
                    createdAt: now,
                    updatedAt: now
                )
            }
            if items.isEmpty { readWithoutItems.insert(sourceID) }
            try await storage.saveMeetingActionItems(items, groupID: groupID, sourceID: sourceID)
            logger.info("Meeting action items for \(sourceID, privacy: .public): \(items.count)")
            return items
        } catch {
            logger.error("Meeting action items for \(sourceID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// How a series' items read back (`list_meeting_action_items` latest_only):
/// the most recent session's, open first, then done, each in extraction
/// order. Pure, mirrored by `meetingActionItemsForPlanner` on the web.
enum MeetingActionItems {
    static func forPlanner(_ items: [MeetingActionItem]) -> [MeetingActionItem] {
        guard let latest = items.max(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.sourceID < rhs.sourceID
        }) else { return [] }
        let session = items.filter { $0.sourceID == latest.sourceID }
        let open = session.filter { !$0.isDone }.sorted { $0.position < $1.position }
        let done = session.filter(\.isDone).sorted { $0.position < $1.position }
        return open + done
    }
}
