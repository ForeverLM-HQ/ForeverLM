import Foundation
import OSLog

/// What one extraction run did.
struct WorkingNoteExtractionReport: Equatable, Sendable {
    var added = 0
    var updated = 0
    var forgotten = 0
    var logEntries = 0
    /// Said in the day close's receipt: nothing to read, or why it could not.
    var note: String?
    var failure: String?
}

/// Turns what the learner did since the last day close into working notes
/// (`WorkingNote`) and a fresh `What I'm working on` Doc (`WorkingLog`).
///
/// Run by the day close (`DayClosePass`), after the chats are folded in: one
/// model call over the chats' tails, the titles of what was read, the Doc's
/// current summary and the notes nearest it (by on-device embedding, so the
/// model updates a note rather than writing it twice). A run with nothing to
/// read costs nothing. It writes only what the model proposed and
/// `WorkingNoteOps.validated` accepts; a failed call changes nothing, and
/// tomorrow's run reads the same activity again.
struct WorkingNoteExtractionPass: Sendable {
    let storage: StorageService
    let aiService: AIService

    static let maximumChats = 8
    static let chatTailCharacters = 4_000
    static let maximumSources = 25
    static let maximumMade = 20
    static let nearbyNoteCount = 12
    private static let logger = Logger(subsystem: "ForeverLM", category: "WorkingNotes")

    func run(
        chats: [KnowledgeStore.DayCloseChatSubject],
        since: Date,
        now: Date,
        config: AITaskConfig
    ) async -> WorkingNoteExtractionReport {
        var report = WorkingNoteExtractionReport()
        guard WorkingNotesPreference.isEnabled else {
            report.note = "Working notes are switched off."
            return report
        }
        do {
            // Edits made in the notes' Doc, here or on another Mac, count
            // before the model reads the nearest notes.
            await storage.syncWorkingNotesMirror()
            let activity = try await activityDescription(chats: chats, since: since, now: now)
            guard !activity.isEmpty else {
                report.note = "No new activity to write notes from."
                return report
            }

            let store = await storage.workingNotes()
            let nearby = await store.nearest(to: String(activity.prefix(1_500)), topK: Self.nearbyNoteCount)
            let logRecord = try await storage.ensureWorkingLog()
            let logSnapshot = try await storage.artifactMarkdown(of: logRecord)
            let summary = WorkingLog.rightNowSection(of: logSnapshot.markdown)

            let extraction = try await aiService.extractWorkingNotes(
                activity: activity, currentSummary: summary, nearby: nearby, now: now, config: config
            )
            let ops = extraction.ops.validated(against: await store.allNotes())
            if !ops.isEmpty { await store.apply(ops, now: now) }
            report.added = ops.add.count
            report.updated = ops.update.count
            report.forgotten = ops.forget.count
            await store.consolidate(now: now)
            await storage.syncWorkingNotesMirror()

            let entries = extraction.log
            if extraction.rightNow != nil || !entries.isEmpty {
                try await writeLog(
                    id: logRecord.id,
                    rightNow: extraction.rightNow,
                    entries: entries,
                    now: now
                )
                report.logEntries = entries.count
            }
        } catch {
            Self.logger.error("Working notes could not be written: \(error.localizedDescription)")
            report.failure = "Working notes could not be written: \(error.localizedDescription)"
        }
        return report
    }

    /// The chats' tails and what was read, as the model reads them. Empty when
    /// there is nothing.
    private func activityDescription(
        chats: [KnowledgeStore.DayCloseChatSubject],
        since: Date,
        now: Date
    ) async throws -> String {
        var sections: [String] = []

        var chatBlocks: [String] = []
        for chat in chats.sorted(by: { $0.lastLearnerTurnAt > $1.lastLearnerTurnAt }).prefix(Self.maximumChats) {
            // A memory review is the card schedule's, already folded in
            // elsewhere; what it says about the learner is its own record.
            guard !chat.isMemoryReview else { continue }
            var transcript = try await storage.dayCloseTranscript(sessionID: chat.sessionID, title: chat.title)
            if transcript.count > Self.chatTailCharacters {
                transcript = "[earlier turns omitted]\n" + String(transcript.suffix(Self.chatTailCharacters))
            }
            chatBlocks.append("CHAT \"\(chat.title)\" (last message \(DailyNote.dayKey(for: chat.lastLearnerTurnAt)))\n\(transcript)")
        }
        if !chatBlocks.isEmpty { sections.append(chatBlocks.joined(separator: "\n\n")) }

        // Notebooks started or changed, and pages written or edited: their
        // titles and a notebook's short description, never a page's body.
        var madeLines: [String] = []
        for notebook in try await storage.loadLearningGoals()
            where notebook.isNotebook && notebook.updatedAt > since && notebook.updatedAt <= now {
            let isNew = notebook.createdAt > since
            let summary = notebook.summary.map { WorkingNote.cleaned($0) }.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            madeLines.append("- Notebook \"\(notebook.title)\" \(isNew ? "started" : "changed")\(summary.map { ": \($0)" } ?? "")")
        }
        let skippedPages: Set<String> = [WorkingLog.id, WorkingNoteMirror.docID]
        for page in try await storage.loadArtifacts()
            where page.teamID == nil && page.kind == nil && page.archivedAt == nil
                && !DailyNote.isDailyNoteID(page.id) && !skippedPages.contains(page.id)
                && page.updatedAt > since && page.updatedAt <= now {
            madeLines.append("- Page \"\(page.title)\" \(page.createdAt > since ? "written" : "edited")")
        }
        if !madeLines.isEmpty {
            sections.append("NOTEBOOKS AND PAGES\n" + madeLines.prefix(Self.maximumMade).joined(separator: "\n"))
        }

        let sourceIDs = try await storage.sourceIDsConsumed(since: since, now: now)
        var sourceLines: [String] = []
        for id in sourceIDs.prefix(Self.maximumSources) {
            guard let source = try? await storage.loadSourceWithoutContent(id),
                  !GeneratedAudioOverview.isCarrier(source) else { continue }
            sourceLines.append("- [\(id)] \(source.title) (\(source.sourceType.rawValue))")
        }
        if !sourceLines.isEmpty {
            sections.append("READ OR LISTENED TO\n" + sourceLines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Read, change, write with the revision read, as an assistant's edit; a
    /// newer body (the learner typing in it) is read again, three times.
    private func writeLog(id: String, rightNow: String?, entries: [String], now: Date) async throws {
        for attempt in 0..<3 {
            let current = try await storage.artifactMarkdown(id)
            let body = WorkingLog.updated(markdown: current.markdown, rightNow: rightNow, entries: entries, now: now)
            guard body != current.markdown else { return }
            do {
                _ = try await storage.writeArtifactMarkdownAndSync(
                    artifactID: id, markdown: body, expectedRevision: current.revision, versionReason: .assistantEdit
                )
                return
            } catch ArtifactError.conflict where attempt < 2 {
                continue
            }
        }
    }
}
