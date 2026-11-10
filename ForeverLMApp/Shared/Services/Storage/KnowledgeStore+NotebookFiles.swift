import Foundation
import SQLite3

extension KnowledgeStore {
    func loadNotebookFiles(notebookID: String) throws -> [NotebookFileRecord] {
        var records: [NotebookFileRecord] = []
        try queryBind("""
            SELECT id, notebook_id, relative_path, name, content_type,
                   size_bytes, modified_at, created_at
            FROM notebook_files
            WHERE notebook_id = ?
            ORDER BY relative_path COLLATE NOCASE
        """, bind: { statement in
            bind(statement, 1, notebookID)
        }) { statement in
            guard let id = string(statement, 0),
                  let storedNotebookID = string(statement, 1),
                  let relativePath = string(statement, 2),
                  let name = string(statement, 3) else {
                return
            }
            records.append(
                NotebookFileRecord(
                    id: id,
                    notebookID: storedNotebookID,
                    relativePath: relativePath,
                    name: name,
                    contentType: string(statement, 4),
                    sizeBytes: sqlite3_column_int64(statement, 5),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 7))
                )
            )
        }
        return records
    }

    /// Brings one notebook's derived file projection in line with the files on disk, atomically: rows for
    /// files that are not there any more go, rows for files that are there are written (only when they
    /// differ, so an unchanged file queues nothing for sync).
    ///
    /// Under generation 2 an inbound file is only an index row until its bytes arrive (`#incoming` on its
    /// Artifact): it is not on disk yet and must stay, because dropping the row feeds a delete of the
    /// Artifact to every device and the Mac that made the file would remove its copy.
    func replaceNotebookFiles(notebookID: String, with records: [NotebookFileRecord]) throws {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            let onDisk = Set(records.map(\.id))
            var gone: [String] = []
            try query("SELECT id, notebook_id, relative_path FROM notebook_files WHERE notebook_id = ?", [.text(notebookID)]) { row in
                guard let id = row.text(0), !onDisk.contains(id) else { return }
                if let wire = NotebookFileArtifact.wireID(notebookID: row.text(1), relativePath: row.text(2)),
                   (try? scalarInteger(
                       "SELECT EXISTS(SELECT 1 FROM artifact_files WHERE artifact_id = ? AND file_key = ?)",
                       [.text(wire), .text(NotebookFileArtifact.incomingKey)]
                   )) == 1 {
                    return
                }
                gone.append(id)
            }
            for id in gone {
                try execute("DELETE FROM notebook_files WHERE id = ?", [.text(id)])
            }
            for record in records {
                try execute("""
                    INSERT INTO notebook_files (
                        id, notebook_id, relative_path, name, role, content_type,
                        size_bytes, modified_at, created_at
                    )
                    VALUES (?, ?, ?, ?, 'file', ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        notebook_id = excluded.notebook_id, relative_path = excluded.relative_path, name = excluded.name,
                        content_type = excluded.content_type, size_bytes = excluded.size_bytes,
                        modified_at = excluded.modified_at, created_at = excluded.created_at
                    WHERE notebook_id IS NOT excluded.notebook_id OR relative_path IS NOT excluded.relative_path
                       OR name IS NOT excluded.name OR content_type IS NOT excluded.content_type
                       OR size_bytes IS NOT excluded.size_bytes OR modified_at IS NOT excluded.modified_at
                       OR created_at IS NOT excluded.created_at
                """, [
                    .text(record.id), .text(record.notebookID), .text(record.relativePath), .text(record.name),
                    .text(record.contentType), .integer(record.sizeBytes),
                    .real(record.modifiedAt.timeIntervalSinceReferenceDate), .real(record.createdAt.timeIntervalSinceReferenceDate),
                ])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
