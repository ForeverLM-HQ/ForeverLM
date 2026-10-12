import Foundation

// MARK: - Working notes (docs/planner-design.md, "The day is planned from a running log")
//
// The notes ForeverLM keeps about how the learner is working, over MCP, so an
// assistant beside the app can read what the app knows about their work, and
// write, correct or forget a note when the learner says so. The day close
// writes most notes; these tools are for what the learner tells an assistant
// ("remember that I want a review after every paper", "forget that note about
// Berlin"). Nothing here calls a model: a read, or a row in the notes file.

extension MCPDataStore {

    static let workingNoteKindList = WorkingNoteKind.allCases.map(\.rawValue).joined(separator: ", ")

    /// Why a Doc tool refuses a working-memory record (`WorkingMemoryRecords`).
    static func workingMemoryIsNoDocMessage(docID: String, tool: String) -> String {
        "\(docID) is ForeverLM's background memory of the learner's work, not a Doc, so \(tool) does not read or change it. list_working_notes reads it (the running summary and the notes); save_working_note, update_working_note and forget_working_note change the notes."
    }

    private static func workingNotePayload(_ note: WorkingNote) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "note_id": note.id,
            "kind": note.kind.rawValue,
            "text": note.text,
            "written_at": formatter.string(from: note.createdAt),
            "updated_at": formatter.string(from: note.updatedAt),
            "recall_count": note.recallCount,
        ]
        if let recalled = note.lastRecalledAt { payload["last_recalled_at"] = formatter.string(from: recalled) }
        if !note.sourceIDs.isEmpty { payload["source_ids"] = note.sourceIDs }
        return payload
    }

    /// A note by its id, or by the start of it (at least eight characters, as a
    /// chat's prompt shows it) when exactly one note starts so.
    static func resolveWorkingNote(_ rawID: String, in notes: [WorkingNote]) throws -> WorkingNote {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw MCPError.invalidInput("note_id is required. list_working_notes gives the ids.")
        }
        if let exact = notes.first(where: { $0.id == id }) { return exact }
        if id.count >= 8 {
            let matches = notes.filter { $0.id.hasPrefix(id) }
            if matches.count == 1, let only = matches.first { return only }
            if matches.count > 1 {
                throw MCPError.invalidInput("\(id) starts more than one note. Pass the whole note_id from list_working_notes.")
            }
        }
        throw MCPError.notFound("No working note has the id \(id). list_working_notes lists them.")
    }

    // MARK: list_working_notes

    func listWorkingNotes(arguments: [String: Any]) async throws -> String {
        let storage = notebookFileStorage
        await storage.syncWorkingNotesMirror()
        let store = await storage.workingNotes()
        let all = await store.allNotes()

        let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 50, 1), 200)
        var kind: WorkingNoteKind?
        if let raw = (arguments["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let parsed = WorkingNoteKind(rawValue: raw.lowercased()) else {
                throw MCPError.invalidInput("kind is one of: \(Self.workingNoteKindList).")
            }
            kind = parsed
        }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var notes: [WorkingNote]
        if query.isEmpty {
            notes = all
        } else {
            // The notes nearest the words, by the same embedding a chat recalls
            // with; reading them here does not count as use.
            notes = await store.nearest(to: query, topK: max(limit, all.count))
        }
        if let kind { notes = notes.filter { $0.kind == kind } }
        let listed = Array(notes.prefix(limit))
        let runningLog = try await storage.workingLogPromptExcerpt()

        return try jsonString([
            "notes": listed.map(Self.workingNotePayload),
            "count": listed.count,
            "total": all.count,
            "enabled": WorkingNotesPreference.isEnabled,
            "running_log": runningLog ?? NSNull(),
            "guidance": all.isEmpty && runningLog == nil
                ? "No notes yet. ForeverLM writes them when the day closes from the learner's chats and reading; save_working_note writes one the learner asks for."
                : "These are notes ForeverLM keeps in the background about how the learner works, newest first (nearest the query first when one is given), and running_log is its running summary of what they are working on: Right now, then the newest log lines. Both may be out of date: trust what the learner says now. They are not Docs; the learner reviews the notes in Settings › Data & Privacy › Notes about your work. Write or change a note only when the learner asks.",
        ] as [String: Any])
    }

    // MARK: save_working_note

    func saveWorkingNote(arguments: [String: Any]) async throws -> String {
        guard let rawText = arguments["text"] as? String,
              !WorkingNote.cleaned(rawText).isEmpty else {
            throw MCPError.invalidInput("text is required: one sentence, at most \(WorkingNote.maximumTextCharacters) characters, that stands on its own.")
        }
        var kind = WorkingNoteKind.fact
        if let raw = (arguments["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let parsed = WorkingNoteKind(rawValue: raw.lowercased()) else {
                throw MCPError.invalidInput("kind is one of: \(Self.workingNoteKindList).")
            }
            kind = parsed
        }
        let sourceIDs = (arguments["source_ids"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let storage = notebookFileStorage
        await storage.syncWorkingNotesMirror()
        let added = await storage.workingNotes().apply(WorkingNoteOps(
            add: [.init(kind: kind.rawValue, text: rawText, sourceIDs: sourceIDs)], update: [], forget: []
        ))
        await storage.syncWorkingNotesMirror()
        guard let note = added.first else {
            // The same sentence was already a note: consolidation folded it in.
            return try jsonString([
                "status": "already_noted",
                "message": "A note with that sentence already exists. list_working_notes shows it.",
            ] as [String: Any])
        }
        var payload = Self.workingNotePayload(note)
        payload["status"] = "saved"
        if !WorkingNotesPreference.isEnabled {
            payload["guidance"] = "Notes are switched off in Settings › Data & Privacy, so ForeverLM does not send this one to its chats until the learner switches them on."
        }
        return try jsonString(payload)
    }

    // MARK: update_working_note

    func updateWorkingNote(arguments: [String: Any]) async throws -> String {
        let storage = notebookFileStorage
        await storage.syncWorkingNotesMirror()
        let store = await storage.workingNotes()
        let note = try Self.resolveWorkingNote(arguments["note_id"] as? String ?? "", in: await store.allNotes())

        var text = note.text
        if let raw = arguments["text"] as? String {
            guard !WorkingNote.cleaned(raw).isEmpty else {
                throw MCPError.invalidInput("text cannot be blank. forget_working_note removes a note.")
            }
            text = raw
        }
        var kind: WorkingNoteKind?
        if let raw = (arguments["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let parsed = WorkingNoteKind(rawValue: raw.lowercased()) else {
                throw MCPError.invalidInput("kind is one of: \(Self.workingNoteKindList).")
            }
            kind = parsed
        }
        guard arguments["text"] is String || kind != nil else {
            throw MCPError.invalidInput("Pass text, kind or both: what to change on the note.")
        }
        await store.edit(id: note.id, text: text, kind: kind)
        await storage.syncWorkingNotesMirror()
        guard let updated = await store.allNotes().first(where: { $0.id == note.id }) else {
            return try jsonString([
                "status": "merged",
                "message": "The new sentence matched another note, so the two are now one.",
            ] as [String: Any])
        }
        var payload = Self.workingNotePayload(updated)
        payload["status"] = "updated"
        return try jsonString(payload)
    }

    // MARK: forget_working_note

    func forgetWorkingNote(arguments: [String: Any]) async throws -> String {
        let storage = notebookFileStorage
        await storage.syncWorkingNotesMirror()
        let store = await storage.workingNotes()
        let note = try Self.resolveWorkingNote(arguments["note_id"] as? String ?? "", in: await store.allNotes())
        await store.forget(id: note.id)
        await storage.syncWorkingNotesMirror()
        return try jsonString([
            "status": "forgotten",
            "note_id": note.id,
            "text": note.text,
            "message": "Forgotten. ForeverLM no longer hands this note to its chats, on this Mac or the learner's others.",
        ] as [String: Any])
    }
}
