import Foundation
import SQLite3

// MARK: - Sensemaking tables (schema 165, docs/sensemaking-design.md)
//
// Three local tables of derived text: an Atlas's body, a source's reading
// levels and a source card's written faces. Each row is written whole and read
// whole, and each can be thrown away and written again; none is synced
// (docs/backend-storage-sync.md, "Not synced").

/// One stored Atlas row; `payloadJSON` is the encoded `Atlas`.
struct AtlasRow: Equatable, Sendable {
    var id: String
    var topic: String
    var notebookID: String?
    var scopeJSON: String
    var payloadJSON: String
    var createdAt: Date
    var updatedAt: Date
}

/// One stored row of a source's reading levels; `payloadJSON` is the encoded
/// `SourceLevels`, written from the text whose SHA-256 is `contentSHA256`.
struct SourceLevelsRow: Equatable, Sendable {
    var sourceID: String
    var contentSHA256: String
    var payloadJSON: String
    var model: String?
    var createdAt: Date
}

/// One source card's written faces on the Canvas.
struct SourceFacesRow: Equatable, Sendable {
    var sourceID: String
    var fingerprint: String
    var far: String
    var mid: String
    var near: [String]
    var model: String?
    var createdAt: Date
}

extension KnowledgeStore {

    // MARK: Atlases

    func saveAtlasRow(_ row: AtlasRow) throws {
        try execBind("""
            INSERT INTO atlases (id, topic, notebook_id, scope_json, payload_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                topic = excluded.topic,
                notebook_id = excluded.notebook_id,
                scope_json = excluded.scope_json,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
        """) { stmt in
            self.bind(stmt, 1, row.id)
            self.bind(stmt, 2, row.topic)
            self.bind(stmt, 3, row.notebookID)
            self.bind(stmt, 4, row.scopeJSON)
            self.bind(stmt, 5, row.payloadJSON)
            self.bind(stmt, 6, row.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 7, row.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    /// Every Atlas, the most recently changed first.
    func atlasRows(limit: Int = 200) throws -> [AtlasRow] {
        var rows: [AtlasRow] = []
        try queryBind("""
            SELECT id, topic, notebook_id, scope_json, payload_json, created_at, updated_at
            FROM atlases ORDER BY updated_at DESC, id LIMIT ?
        """, bind: { stmt in
            self.bind(stmt, 1, limit)
        }) { stmt in
            if let row = self.atlasRow(from: stmt) { rows.append(row) }
        }
        return rows
    }

    func atlasRow(id: String) throws -> AtlasRow? {
        var found: AtlasRow?
        try queryBind("""
            SELECT id, topic, notebook_id, scope_json, payload_json, created_at, updated_at
            FROM atlases WHERE id = ? LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, id)
        }) { stmt in
            found = self.atlasRow(from: stmt)
        }
        return found
    }

    func deleteAtlasRow(id: String) throws {
        try execBind("DELETE FROM atlases WHERE id = ?") { stmt in
            self.bind(stmt, 1, id)
        }
    }

    private func atlasRow(from stmt: OpaquePointer?) -> AtlasRow? {
        guard let id = string(stmt, 0), let topic = string(stmt, 1), let payload = string(stmt, 4) else { return nil }
        return AtlasRow(
            id: id,
            topic: topic,
            notebookID: string(stmt, 2),
            scopeJSON: string(stmt, 3) ?? "{}",
            payloadJSON: payload,
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
        )
    }

    // MARK: Reading levels

    func saveSourceLevelsRow(_ row: SourceLevelsRow) throws {
        try execBind("""
            INSERT INTO source_levels (source_id, content_sha256, payload_json, model, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                content_sha256 = excluded.content_sha256,
                payload_json = excluded.payload_json,
                model = excluded.model,
                created_at = excluded.created_at
        """) { stmt in
            self.bind(stmt, 1, row.sourceID)
            self.bind(stmt, 2, row.contentSHA256)
            self.bind(stmt, 3, row.payloadJSON)
            self.bind(stmt, 4, row.model)
            self.bind(stmt, 5, row.createdAt.timeIntervalSinceReferenceDate)
        }
    }

    func sourceLevelsRow(sourceID: String) throws -> SourceLevelsRow? {
        var found: SourceLevelsRow?
        try queryBind("""
            SELECT source_id, content_sha256, payload_json, model, created_at
            FROM source_levels WHERE source_id = ? LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let id = self.string(stmt, 0), let sha = self.string(stmt, 1), let payload = self.string(stmt, 2) else { return }
            found = SourceLevelsRow(
                sourceID: id,
                contentSHA256: sha,
                payloadJSON: payload,
                model: self.string(stmt, 3),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            )
        }
        return found
    }

    func deleteSourceLevelsRow(sourceID: String) throws {
        try execBind("DELETE FROM source_levels WHERE source_id = ?") { stmt in
            self.bind(stmt, 1, sourceID)
        }
    }

    // MARK: Written faces

    func saveSourceFacesRows(_ rows: [SourceFacesRow]) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            for row in rows {
                let near = (try? JSONEncoder().encode(row.near)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try execBind("""
                    INSERT INTO source_faces (source_id, fingerprint, far, mid, near_json, model, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_id) DO UPDATE SET
                        fingerprint = excluded.fingerprint,
                        far = excluded.far,
                        mid = excluded.mid,
                        near_json = excluded.near_json,
                        model = excluded.model,
                        created_at = excluded.created_at
                """) { stmt in
                    self.bind(stmt, 1, row.sourceID)
                    self.bind(stmt, 2, row.fingerprint)
                    self.bind(stmt, 3, row.far)
                    self.bind(stmt, 4, row.mid)
                    self.bind(stmt, 5, near)
                    self.bind(stmt, 6, row.model)
                    self.bind(stmt, 7, row.createdAt.timeIntervalSinceReferenceDate)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The written faces of these sources, by source id; every row when `sourceIDs` is nil.
    func sourceFacesRows(sourceIDs: [String]? = nil) throws -> [String: SourceFacesRow] {
        var rows: [String: SourceFacesRow] = [:]
        let handler: (OpaquePointer?) throws -> Void = { stmt in
            guard let id = self.string(stmt, 0),
                  let fingerprint = self.string(stmt, 1),
                  let far = self.string(stmt, 2),
                  let mid = self.string(stmt, 3) else { return }
            let nearJSON = self.string(stmt, 4) ?? "[]"
            let near = (try? JSONDecoder().decode([String].self, from: Data(nearJSON.utf8))) ?? []
            rows[id] = SourceFacesRow(
                sourceID: id,
                fingerprint: fingerprint,
                far: far,
                mid: mid,
                near: near,
                model: self.string(stmt, 5),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
            )
        }
        let columns = "SELECT source_id, fingerprint, far, mid, near_json, model, created_at FROM source_faces"
        guard let sourceIDs else {
            try query(columns, handler)
            return rows
        }
        guard !sourceIDs.isEmpty else { return [:] }
        for chunk in stride(from: 0, to: sourceIDs.count, by: 400).map({ Array(sourceIDs[$0 ..< min($0 + 400, sourceIDs.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            try queryBind("\(columns) WHERE source_id IN (\(placeholders))", bind: { stmt in
                for (index, id) in chunk.enumerated() { self.bind(stmt, index + 1, id) }
            }, handler)
        }
        return rows
    }
}
