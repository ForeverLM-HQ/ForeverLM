import Foundation
import OSLog

/// The working notes (`WorkingNote`) of one library, in a JSON file beside the
/// knowledge database. Local on purpose: the vectors are derived data that
/// never sync, as the source index's don't, and a note is cheap to write
/// again; a library on a second Mac builds its own from its own day. (The
/// working log Doc, which does sync, is the summary both Macs share.)
///
/// An actor over one file. Reads and writes are whole-file: a few hundred
/// short notes with 512-float vectors is well under a megabyte, written
/// atomically.
actor WorkingNoteStore {
    private static let logger = Logger(subsystem: "ForeverLM", category: "WorkingNotes")
    static let fileName = "working-notes.json"

    /// One store per directory, so every caller in the process shares one
    /// in-memory copy and one writer.
    private static let registry = NSLock()
    nonisolated(unsafe) private static var stores: [String: WorkingNoteStore] = [:]

    static func shared(directory: URL, embed: @escaping @Sendable (String) async throws -> [Float] = { try await AppleTextEmbedder.embed($0) }) -> WorkingNoteStore {
        registry.lock()
        defer { registry.unlock() }
        let key = directory.standardizedFileURL.path
        if let existing = stores[key] { return existing }
        let store = WorkingNoteStore(directory: directory, embed: embed)
        stores[key] = store
        return store
    }

    /// What the file holds: the notes, and what is known of the Doc that
    /// mirrors them (`WorkingNoteMirror`).
    private struct FileContents: Codable {
        var notes: [WorkingNote]
        /// The Doc's revision this file last read or wrote; nil before the
        /// first sync.
        var mirrorRevision: String?
        /// The normalized sentences last written into the Doc.
        var exported: [String]
    }

    private let fileURL: URL
    private let embed: @Sendable (String) async throws -> [Float]
    private var loaded: [WorkingNote]?
    private var mirrorRevision: String?
    private var exported: Set<String> = []

    init(directory: URL, embed: @escaping @Sendable (String) async throws -> [Float]) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.embed = embed
    }

    // MARK: Reading

    func allNotes() -> [WorkingNote] {
        currentNotes().sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    /// The notes nearest `query` (what the learner just said and what the chat
    /// is about), best first. An empty query, or an embedding that fails,
    /// ranks by recency and use alone: a chat is never held up by recall.
    /// Recalling a note counts as use.
    func recall(query: String, topK: Int, now: Date = Date()) async -> [WorkingNote] {
        let notes = currentNotes()
        guard !notes.isEmpty, topK > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var queryVector: [Float]?
        if !trimmed.isEmpty {
            queryVector = try? await embed(Self.embeddable(trimmed))
        }
        // Notes written while the embedder was unavailable get theirs now.
        await embedMissingVectors()

        let ranked = WorkingNoteRanking.rank(
            currentNotes(),
            queryVector: queryVector,
            embeddingModel: EmbeddingSettings.modelID,
            topK: topK
        )
        guard !ranked.isEmpty else { return [] }
        let ids = Set(ranked.map(\.id))
        var updated = currentNotes()
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].lastRecalledAt = now
            updated[index].recallCount += 1
        }
        save(updated)
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        return ranked.compactMap { byID[$0.id] }
    }

    /// The notes nearest `text`, for the extraction pass to show the model so
    /// it updates rather than repeats. Reads without counting as use.
    func nearest(to text: String, topK: Int) async -> [WorkingNote] {
        let notes = currentNotes()
        guard !notes.isEmpty, topK > 0 else { return [] }
        let vector = try? await embed(Self.embeddable(text))
        await embedMissingVectors()
        return WorkingNoteRanking.rank(
            currentNotes(), queryVector: vector, embeddingModel: EmbeddingSettings.modelID, topK: topK
        )
    }

    // MARK: Writing

    /// Applies what a model (or a chat) proposed, already `validated`. Returns
    /// the notes added, so a caller can say what it learned.
    @discardableResult
    func apply(_ ops: WorkingNoteOps, now: Date = Date()) async -> [WorkingNote] {
        var notes = currentNotes()
        let validated = ops.validated(against: notes)

        let forgotten = Set(validated.forget)
        notes.removeAll { forgotten.contains($0.id) }

        for revision in validated.update {
            guard let index = notes.firstIndex(where: { $0.id == revision.id }) else { continue }
            notes[index].text = WorkingNote.cleaned(revision.text)
            notes[index].updatedAt = now
            notes[index].vector = nil
            notes[index].embeddingModel = nil
        }

        var added: [WorkingNote] = []
        for addition in validated.add {
            guard let kind = WorkingNoteKind(rawValue: addition.kind) else { continue }
            let note = WorkingNote(kind: kind, text: addition.text, sourceIDs: addition.sourceIDs, now: now)
            notes.append(note)
            added.append(note)
        }

        notes = WorkingNoteConsolidation.consolidate(notes, now: now)
        save(notes)
        await embedMissingVectors()
        let survivors = Set(currentNotes().map(\.id))
        return added.filter { survivors.contains($0.id) }
    }

    /// The deterministic tidy: duplicates folded, ended threads dropped, the
    /// store bounded. Safe to run at any time.
    func consolidate(now: Date = Date()) {
        save(WorkingNoteConsolidation.consolidate(currentNotes(), now: now))
    }

    /// The learner's own corrections, from Settings or an assistant they asked.
    func edit(id: String, text: String, kind: WorkingNoteKind? = nil, now: Date = Date()) {
        var notes = currentNotes()
        let cleaned = WorkingNote.cleaned(text)
        guard !cleaned.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[index].text != cleaned {
            notes[index].text = cleaned
            notes[index].vector = nil
            notes[index].embeddingModel = nil
        }
        if let kind { notes[index].kind = kind }
        notes[index].updatedAt = now
        save(WorkingNoteConsolidation.consolidate(notes, now: now))
    }

    /// Forgets one note, or all of them. Forgotten notes stay in the Doc until
    /// the next sync removes their lines.
    @discardableResult
    func forget(id: String) -> Bool {
        var notes = currentNotes()
        let before = notes.count
        notes.removeAll { $0.id == id }
        guard notes.count != before else { return false }
        save(notes)
        return true
    }

    func forgetAll() {
        _ = currentNotes()
        save([])
    }

    // MARK: The Doc that mirrors the notes

    struct MirrorSync: Equatable, Sendable {
        /// The Doc's body as it should now read.
        let markdown: String
        /// Whether that differs from what the Doc holds, so a write is due.
        let needsWrite: Bool
    }

    /// Reads the Doc's body in: edits made there (here, on another Mac, by the
    /// learner) become changes to the notes, when the Doc has moved since this
    /// file last saw it. Answers what the Doc should now say.
    func syncWithMirror(markdown: String, revision: String, now: Date = Date()) async -> MirrorSync {
        _ = currentNotes()
        if mirrorRevision != revision {
            let merged = WorkingNoteMirror.merge(
                local: currentNotes(),
                doc: WorkingNoteMirror.parse(markdown),
                exported: exported,
                now: now
            )
            save(WorkingNoteConsolidation.consolidate(merged, now: now))
            await embedMissingVectors()
        }
        let rendered = WorkingNoteMirror.render(currentNotes())
        let current = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsWrite = rendered.trimmingCharacters(in: .whitespacesAndNewlines) != current
        if !needsWrite {
            recordMirror(revision: revision)
        }
        return MirrorSync(markdown: rendered, needsWrite: needsWrite)
    }

    /// The Doc now holds what `syncWithMirror` said, at `revision`.
    func recordMirror(revision: String) {
        mirrorRevision = revision
        exported = Set(currentNotes().map(\.normalizedText))
        save(currentNotes())
    }

    // MARK: Embedding

    /// Notes embed under their kind and sentence together, so a query about
    /// "Berlin" can find a fact and a thread alike.
    static func embeddable(_ text: String) -> String {
        String(text.prefix(WorkingNote.maximumTextCharacters))
    }

    private func embedMissingVectors() async {
        let model = EmbeddingSettings.modelID
        let pending = currentNotes()
            .filter { $0.embeddingModel != model || $0.vector == nil }
            .map { ($0.id, $0.text) }
        var changed = false
        for (id, text) in pending {
            guard let vector = try? await embed(Self.embeddable(text)) else { continue }
            // The notes can have changed while the embedder ran.
            var notes = currentNotes()
            guard let index = notes.firstIndex(where: { $0.id == id && $0.text == text }) else { continue }
            notes[index].vector = vector
            notes[index].embeddingModel = model
            loaded = notes
            changed = true
        }
        if changed { save(currentNotes()) }
    }

    // MARK: File

    private func currentNotes() -> [WorkingNote] {
        if let loaded { return loaded }
        var notes: [WorkingNote] = []
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let contents = try? decoder.decode(FileContents.self, from: data) {
                notes = contents.notes
                mirrorRevision = contents.mirrorRevision
                exported = Set(contents.exported)
            } else if let plain = try? decoder.decode([WorkingNote].self, from: data) {
                notes = plain
            } else {
                // A file that will not read is moved aside, not overwritten
                // by the next save: the notes in it may still be wanted.
                Self.logger.error("Working notes could not be read, moved aside")
                let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
        }
        loaded = notes
        return notes
    }

    private func save(_ notes: [WorkingNote]) {
        loaded = notes
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let contents = FileContents(notes: notes, mirrorRevision: mirrorRevision, exported: exported.sorted())
            try encoder.encode(contents).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Working notes could not be saved: \(error.localizedDescription)")
        }
    }
}
