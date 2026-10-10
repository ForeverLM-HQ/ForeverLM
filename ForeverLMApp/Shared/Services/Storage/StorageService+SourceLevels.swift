import Foundation

// MARK: - A source's reading levels in storage
//
// docs/sensemaking-design.md, "Levels in the Reader". One row a source in the
// local `source_levels` table (schema 165): the levels as JSON, kept against
// the SHA-256 of the text they were written from. Derived and rewritable,
// never synced. Read and written through the storage actor, so neither the
// Reader nor `get_source_levels` touches the cached MCP connection.

extension StorageService {
    /// A source's stored levels, or nil when none are written. A row that no
    /// longer reads as levels is an error, never "none".
    func sourceLevels(sourceID: String) throws -> SourceLevels? {
        guard let row = try notebookFilesKnowledgeStore().sourceLevelsRow(sourceID: sourceID) else { return nil }
        return try SourceLevelsCoding.levels(from: row)
    }

    /// Saves a source's levels over any written before.
    func saveSourceLevels(_ levels: SourceLevels) throws {
        try notebookFilesKnowledgeStore().saveSourceLevelsRow(SourceLevelsCoding.row(for: levels))
    }

    /// A source's stored levels and the SHA-256 of its stored text as it is
    /// now, read together for the panel and `get_source_levels`: the levels
    /// are stale when the two differ. Reads only — the stored text, never
    /// one derived from a file, which `loadSourceContent` would also save —
    /// so opening the panel writes nothing. The hash is nil when no text is
    /// stored.
    func sourceLevelsState(sourceID: String) throws -> (levels: SourceLevels?, currentSHA256: String?, text: String?) {
        let levels = try sourceLevels(sourceID: sourceID)
        let text = loadStoredSourceContents(for: [sourceID])[sourceID]
        let hasText = text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        return (levels, hasText ? text.map(PaperContentPreparationService.sha256) : nil, hasText ? text : nil)
    }
}

enum SourceLevelsCoding {
    struct Unreadable: LocalizedError {
        var errorDescription: String? {
            "The stored levels of this source could not be read. Rewrite writes them again."
        }
    }

    static func row(for levels: SourceLevels) throws -> SourceLevelsRow {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(decoding: try encoder.encode(levels), as: UTF8.self)
        return SourceLevelsRow(
            sourceID: levels.sourceID,
            contentSHA256: levels.contentSHA256,
            payloadJSON: payload,
            model: levels.model,
            createdAt: levels.createdAt
        )
    }

    static func levels(from row: SourceLevelsRow) throws -> SourceLevels {
        guard var levels = try? JSONDecoder().decode(SourceLevels.self, from: Data(row.payloadJSON.utf8)) else {
            throw Unreadable()
        }
        // The row's columns are what a write keyed it by.
        levels.sourceID = row.sourceID
        levels.contentSHA256 = row.contentSHA256
        return levels
    }
}
