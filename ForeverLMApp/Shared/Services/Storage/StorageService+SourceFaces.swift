import Foundation

// MARK: - Written faces: what they are read from and where they are kept (WP-B1)
//
// docs/sensemaking-design.md, "Written faces". The rows live in
// `source_faces` (KnowledgeStore+Sensemaking.swift), local to this Mac and
// rewritable. A face is written from a source's extracted ideas when it has
// some, else from the start of its stored text; only that start is read here,
// never the whole text.

extension StorageService {
    /// The stored faces of these sources, by source id.
    func sourceFacesRows(sourceIDs: [String]) throws -> [String: SourceFacesRow] {
        guard !sourceIDs.isEmpty else { return [:] }
        return try notebookFilesKnowledgeStore().sourceFacesRows(sourceIDs: sourceIDs)
    }

    func saveSourceFacesRows(_ rows: [SourceFacesRow]) throws {
        guard !rows.isEmpty else { return }
        try notebookFilesKnowledgeStore().saveSourceFacesRows(rows)
    }

    /// What each source's faces are written from: the first `characters` of
    /// its stored text and its active ideas' statements. A source with
    /// neither is left out.
    func sourceFaceTexts(sourceIDs: [String], characters: Int = KnowledgeMapFaces.fingerprintCharacters) throws -> [String: KnowledgeMapFaces.SourceText] {
        let ids = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [:] }
        let store = try notebookFilesKnowledgeStore()
        var starts: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start ..< min(start + 400, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            try store.queryBind(
                "SELECT source_id, substr(content, 1, ?) FROM source_content WHERE source_id IN (\(placeholders))",
                bind: { stmt in
                    store.bind(stmt, 1, characters)
                    for (index, id) in chunk.enumerated() { store.bind(stmt, index + 2, id) }
                }
            ) { stmt in
                guard let id = store.string(stmt, 0), let text = store.string(stmt, 1),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                starts[id] = text
            }
        }
        var ideas: [String: [String]] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start ..< min(start + 400, ids.count)])
            for (id, list) in try store.loadSourceIdeas(sourceIDs: chunk) {
                let statements = list.map { $0.statement.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !statements.isEmpty { ideas[id] = statements }
            }
        }
        var texts: [String: KnowledgeMapFaces.SourceText] = [:]
        for id in ids {
            let text = KnowledgeMapFaces.SourceText(start: starts[id] ?? "", ideas: ideas[id] ?? [])
            if !text.isEmpty { texts[id] = text }
        }
        return texts
    }
}
