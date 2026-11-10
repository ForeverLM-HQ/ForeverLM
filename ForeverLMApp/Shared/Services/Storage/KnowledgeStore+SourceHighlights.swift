import Foundation
import SQLite3

/// Reader highlights and the notes written on them.
///
/// Rows are per-source and delete with their source via the foreign key. Each
/// row is also its own CloudKit entity so source metadata saves from older
/// clients cannot erase annotations they do not understand.
extension KnowledgeStore {
    /// Every highlight on a source, oldest first — reading order, which is also
    /// the order the notes list shows them in for non-paginated readers.
    ///
    /// Under generation 2 a highlight is kept on the source's wire id, so a team
    /// copy's reader also lists what was marked on the personal copy (§3.5.17).
    func sourceHighlights(sourceID: String) throws -> [SourceHighlight] {
        var results: [SourceHighlight] = []
        let keys = try personalStateSourceKeys(sourceID)
        try queryBind("""
            SELECT highlight_id, source_id, page_index, quads_json, text, color,
                   note, created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset,
                   chat_session_id, references_json, publication_update, publication_update_at
            FROM source_highlights
            WHERE source_id IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", ")))
            ORDER BY created_at, highlight_id
        """, bind: { stmt in
            for (offset, key) in keys.enumerated() { bind(stmt, offset + 1, key) }
        }) { stmt in
            if let highlight = self.decodeSourceHighlight(stmt) {
                results.append(highlight)
            }
        }
        return results
    }

    /// Highlights for a set of sources at once, keyed by source ID. A book or
    /// course reader shows one chapter at a time but wants its siblings' counts
    /// without a query per chapter.
    func sourceHighlights(sourceIDs: [String]) throws -> [String: [SourceHighlight]] {
        guard !sourceIDs.isEmpty else { return [:] }
        // Each source's highlights on its wire id, filed under the id the caller asked by.
        var asked: [String: [String]] = [:]
        for sourceID in sourceIDs { asked[try personalStateSourceKey(sourceID), default: []].append(sourceID) }
        guard asked.keys.sorted() != Set(sourceIDs).sorted() else { return try sourceHighlightRows(sourceIDs: sourceIDs) }
        var results: [String: [SourceHighlight]] = [:]
        for (key, highlights) in try sourceHighlightRows(sourceIDs: Array(asked.keys)) {
            for sourceID in asked[key] ?? [] { results[sourceID] = highlights }
        }
        return results
    }

    /// Every mark in the library whose color says "come back to this" (blue,
    /// pink: `SourceHighlightColor.isOpenItem`), newest first, each with the
    /// id of the source it is on here. Under generation 2 a team copy's marks
    /// are kept on the source's wire id; they are mapped to the local source,
    /// and a mark whose source this Mac does not hold is left out.
    func openSourceHighlights() throws -> [FollowUpMark] {
        let open = SourceHighlightColor.allCases.filter(\.isOpenItem).map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var rows: [SourceHighlight] = []
        try queryBind("""
            SELECT highlight_id, source_id, page_index, quads_json, text, color,
                   note, created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset,
                   chat_session_id, references_json, publication_update, publication_update_at
            FROM source_highlights
            WHERE color IN (\(open))
            ORDER BY created_at DESC, highlight_id
        """, bind: { _ in }) { stmt in
            if let highlight = self.decodeSourceHighlight(stmt) { rows.append(highlight) }
        }
        var localIDs: [String: String?] = [:]
        var marks: [FollowUpMark] = []
        for highlight in rows {
            let key = highlight.sourceID
            if !localIDs.keys.contains(key) {
                localIDs[key] = .some(try localSourceID(forWireKey: key))
            }
            if let local = localIDs[key] ?? nil {
                marks.append(FollowUpMark(highlight: highlight, sourceID: local))
            }
        }
        return marks
    }

    /// Highlights by the source id their rows hold.
    private func sourceHighlightRows(sourceIDs: [String]) throws -> [String: [SourceHighlight]] {
        var results: [String: [SourceHighlight]] = [:]
        // Chunked so a large book never builds a statement past SQLite's
        // variable limit.
        for chunk in stride(from: 0, to: sourceIDs.count, by: 400).map({ start in
            Array(sourceIDs[start..<min(start + 400, sourceIDs.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try queryBind("""
                SELECT highlight_id, source_id, page_index, quads_json, text, color,
                       note, created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset,
                       chat_session_id, references_json, publication_update, publication_update_at
                FROM source_highlights
                WHERE source_id IN (\(placeholders))
                ORDER BY created_at, highlight_id
            """, bind: { stmt in
                for (offset, sourceID) in chunk.enumerated() {
                    bind(stmt, offset + 1, sourceID)
                }
            }) { stmt in
                if let highlight = self.decodeSourceHighlight(stmt) {
                    results[highlight.sourceID, default: []].append(highlight)
                }
            }
        }
        return results
    }

    /// Inserts a highlight, or replaces one already under that ID. Editing a
    /// note keeps the original `created_at` so the notes list does not reshuffle
    /// when the reader fixes a typo.
    func saveSourceHighlight(_ highlight: SourceHighlight) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try saveSourceHighlightRow(highlight)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Links a mark to the chat its note comes from, or unlinks it with nil.
    /// Returns the mark as saved, or nil when there is no such mark — a mark
    /// removed while its chat was being opened leaves nothing to link. The
    /// note, color and passage are left exactly as they are.
    @discardableResult
    func linkSourceHighlight(id: String, toChat sessionID: String?) throws -> SourceHighlight? {
        guard var highlight = try sourceHighlight(id: id) else { return nil }
        let linked = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = linked?.isEmpty == false ? linked : nil
        guard highlight.linkedChatID != target else { return highlight }
        highlight.chatSessionID = target
        highlight.updatedAt = Date()
        try saveSourceHighlight(highlight)
        return highlight
    }

    /// Adds highlights brought in from another app and returns how many were
    /// new. One already here under its id — the same mark imported before,
    /// perhaps with a note written on it since — is left as it is. So is one
    /// on a passage the source already has marked, unless it brings a note
    /// that mark lacks: importing a library twice, or a mark that Zotero and
    /// the PDF file both hold, adds nothing twice, while a comment pinned
    /// beside a line that is also highlighted still arrives.
    @discardableResult
    func insertImportedSourceHighlights(_ highlights: [SourceHighlight]) throws -> Int {
        guard !highlights.isEmpty else { return 0 }
        try exec("BEGIN IMMEDIATE")
        do {
            let sourceIDs = Array(Set(highlights.map(\.sourceID)))
            var knownIDs = Set<String>()
            // source → passage → the notes already on it.
            var knownNotes: [String: [String: Set<String>]] = [:]
            for sourceID in sourceIDs {
                knownIDs.formUnion(try sourceHighlightIDs(sourceID: sourceID))
            }
            for (sourceID, existing) in try sourceHighlights(sourceIDs: sourceIDs) {
                for highlight in existing {
                    knownNotes[sourceID, default: [:]][ReaderTextAnchor.normalize(highlight.quote).text, default: []]
                        .insert(ReaderTextAnchor.normalize(highlight.note).text)
                }
            }
            var inserted = 0
            for highlight in highlights {
                let passage = ReaderTextAnchor.normalize(highlight.quote).text
                let note = ReaderTextAnchor.normalize(highlight.note).text
                guard !passage.isEmpty, !knownIDs.contains(highlight.id) else { continue }
                if let notes = knownNotes[highlight.sourceID]?[passage], note.isEmpty || notes.contains(note) {
                    continue
                }
                guard try sourceExists(highlight.sourceID) else { continue }
                try saveSourceHighlightRow(highlight)
                knownIDs.insert(highlight.id)
                knownNotes[highlight.sourceID, default: [:]][passage, default: []].insert(note)
                inserted += 1
            }
            try exec("COMMIT")
            return inserted
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func saveSourceHighlightRow(_ highlight: SourceHighlight) throws {
        // Generation 2 keeps a highlight on the source's wire id (§3.5.17).
        let sourceKey = try personalStateSourceKey(highlight.sourceID)
        try execBind("""
            INSERT INTO source_highlights (
                highlight_id, source_id, page_index, quads_json, text, color,
                note, created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset,
                chat_session_id, references_json, publication_update, publication_update_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(highlight_id) DO UPDATE SET
                source_id = excluded.source_id,
                page_index = excluded.page_index,
                quads_json = excluded.quads_json,
                text = excluded.text,
                color = excluded.color,
                note = excluded.note,
                updated_at = excluded.updated_at,
                anchor_prefix = excluded.anchor_prefix,
                anchor_suffix = excluded.anchor_suffix,
                anchor_offset = excluded.anchor_offset,
                chat_session_id = excluded.chat_session_id,
                references_json = excluded.references_json,
                publication_update = excluded.publication_update,
                publication_update_at = excluded.publication_update_at
        """) { stmt in
            bind(stmt, 1, highlight.id)
            bind(stmt, 2, sourceKey)
            bind(stmt, 3, highlight.pdfAnchor?.pageIndex ?? 0)
            // PDF quads, or a web mark's pictures — see `geometryJSON`.
            bind(stmt, 4, highlight.geometryJSON)
            bind(stmt, 5, highlight.quote)
            bind(stmt, 6, highlight.color.rawValue)
            bind(stmt, 7, highlight.note.isEmpty ? nil : highlight.note)
            bind(stmt, 8, highlight.createdAt.timeIntervalSince1970)
            bind(stmt, 9, highlight.updatedAt.timeIntervalSince1970)
            bind(stmt, 10, highlight.anchor.prefix)
            bind(stmt, 11, highlight.anchor.suffix)
            bind(stmt, 12, highlight.anchor.offset)
            bind(stmt, 13, highlight.linkedChatID)
            bind(stmt, 14, SourceHighlightReference.storedJSON(highlight.references))
            bind(stmt, 15, highlight.hasPublicationUpdate ? highlight.publicationUpdate : nil)
            bind(stmt, 16, highlight.hasPublicationUpdate ? highlight.publicationUpdateAt?.timeIntervalSince1970 : nil)
        }
    }

    func deleteSourceHighlight(id: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try deleteSourceHighlightRecord(id: id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteSourceHighlightRecord(id: String) throws {
        try execBind("DELETE FROM source_highlights WHERE highlight_id = ?") { stmt in
            bind(stmt, 1, id)
        }
    }

    func sourceHighlight(id: String) throws -> SourceHighlight? {
        var result: SourceHighlight?
        try queryBind("""
            SELECT highlight_id, source_id, page_index, quads_json, text, color,
                   note, created_at, updated_at, anchor_prefix, anchor_suffix, anchor_offset,
                   chat_session_id, references_json, publication_update, publication_update_at
            FROM source_highlights
            WHERE highlight_id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            result = self.decodeSourceHighlight(stmt)
        }
        return result
    }

    func sourceHighlightIDs(sourceID: String) throws -> [String] {
        var ids: [String] = []
        let keys = try personalStateSourceKeys(sourceID)
        try queryBind(
            "SELECT highlight_id FROM source_highlights WHERE source_id IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", "))) ORDER BY highlight_id",
            bind: { stmt in for (offset, key) in keys.enumerated() { bind(stmt, offset + 1, key) } }
        ) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// SQL that holds for every mark but a bare slide of a talk
    /// (`SourceHighlight.isBareSlideMark`): the canvas made those, so they are
    /// no annotation of the learner's. Anchors are stored with escaped
    /// slashes (`\/`), so both spellings are matched.
    static let notBareSlideMark = """
        NOT (TRIM(COALESCE(text, '')) = '' AND TRIM(COALESCE(note, '')) = '' \
        AND (quads_json LIKE '%/slide/%' OR quads_json LIKE '%\\/slide\\/%'))
        """

    func sourceHighlightCount(sourceID: String) throws -> Int {
        var count = 0
        let keys = try personalStateSourceKeys(sourceID)
        try queryBind(
            "SELECT COUNT(*) FROM source_highlights WHERE source_id IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", "))) AND \(Self.notBareSlideMark)",
            bind: { stmt in for (offset, key) in keys.enumerated() { bind(stmt, offset + 1, key) } }
        ) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    // MARK: Decoding

    private func decodeSourceHighlight(_ stmt: OpaquePointer?) -> SourceHighlight? {
        guard let id = string(stmt, 0), let sourceID = string(stmt, 1) else { return nil }
        let quote = string(stmt, 4) ?? ""
        let quadsJSON = string(stmt, 3) ?? "[]"
        // A mark with no words is a mark on pictures, or nothing at all.
        let imageAnchors = ReaderImageAnchor.anchors(storedJSON: quadsJSON)
        guard !quote.isEmpty || !imageAnchors.isEmpty else { return nil }

        let pageIndex = Int(sqlite3_column_int64(stmt, 2))
        let anchor = ReaderTextAnchor(
            exact: quote,
            prefix: string(stmt, 9) ?? "",
            suffix: string(stmt, 10) ?? "",
            offset: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 11))
        )

        return SourceHighlight(
            id: id,
            sourceID: sourceID,
            quote: quote,
            note: string(stmt, 6) ?? "",
            color: SourceHighlightColor(storedValue: string(stmt, 5)),
            anchor: anchor,
            pdfAnchor: ReaderPDFAnchor(pageIndex: pageIndex, quadsJSON: quadsJSON),
            imageAnchors: imageAnchors,
            chatSessionID: string(stmt, 12),
            references: SourceHighlightReference.references(storedJSON: string(stmt, 13)),
            publicationUpdate: string(stmt, 14) ?? "",
            publicationUpdateAt: sqlite3_column_type(stmt, 15) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        )
    }
}
