import Foundation
import SQLite3

extension KnowledgeStore {
    func loadArtifactComments(_ artifactID: String) throws -> [ArtifactCommentRecord] {
        var comments: [ArtifactCommentRecord] = []
        try queryBind("""
            SELECT id, artifact_id, parent_comment_id, author_record_name,
                   author_display_name, body, anchor_revision, anchor_start,
                   anchor_end, anchor_quote, created_at, updated_at, resolved_at
            FROM artifact_comments
            WHERE artifact_id = ?
            ORDER BY created_at, id
        """, bind: { statement in
            bind(statement, 1, artifactID)
        }) { statement in
            guard let id = string(statement, 0),
                  let artifactID = string(statement, 1),
                  let authorRecordName = string(statement, 3),
                  let authorDisplayName = string(statement, 4),
                  let body = string(statement, 5),
                  let anchorRevision = string(statement, 6),
                  let anchorQuote = string(statement, 9) else { return }
            comments.append(ArtifactCommentRecord(
                id: id,
                artifactID: artifactID,
                parentCommentID: string(statement, 2),
                authorRecordName: authorRecordName,
                authorDisplayName: authorDisplayName,
                body: body,
                anchorRevision: anchorRevision,
                anchorStart: Int(sqlite3_column_int64(statement, 7)),
                anchorEnd: Int(sqlite3_column_int64(statement, 8)),
                anchorQuote: anchorQuote,
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 10)),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 11)),
                resolvedAt: sqlite3_column_type(statement, 12) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 12))
            ))
        }
        return comments
    }

    func loadArtifactCommentForSync(_ commentID: String) throws -> ArtifactCommentRecord? {
        var artifactID: String?
        try queryBind(
            "SELECT artifact_id FROM artifact_comments WHERE id = ? LIMIT 1",
            bind: { statement in bind(statement, 1, commentID) }
        ) { statement in
            artifactID = string(statement, 0)
        }
        guard let artifactID else { return nil }
        return try loadArtifactComments(artifactID).first { $0.id == commentID }
    }

    func saveArtifactCommentRecord(_ comment: ArtifactCommentRecord) throws {
        let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard comment.anchorStart >= 0, comment.anchorEnd >= comment.anchorStart else {
            throw ArtifactCommentError.missingSelection
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO artifact_comments (
                    id, artifact_id, parent_comment_id, author_record_name,
                    author_display_name, body, anchor_revision, anchor_start,
                    anchor_end, anchor_quote, created_at, updated_at, resolved_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    artifact_id = excluded.artifact_id,
                    parent_comment_id = excluded.parent_comment_id,
                    author_record_name = excluded.author_record_name,
                    author_display_name = excluded.author_display_name,
                    body = excluded.body,
                    anchor_revision = excluded.anchor_revision,
                    anchor_start = excluded.anchor_start,
                    anchor_end = excluded.anchor_end,
                    anchor_quote = excluded.anchor_quote,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    resolved_at = excluded.resolved_at
            """) { statement in
                bind(statement, 1, comment.id)
                bind(statement, 2, comment.artifactID)
                bind(statement, 3, comment.parentCommentID)
                bind(statement, 4, comment.authorRecordName)
                bind(statement, 5, comment.authorDisplayName)
                bind(statement, 6, body)
                bind(statement, 7, comment.anchorRevision)
                sqlite3_bind_int64(statement, 8, sqlite3_int64(comment.anchorStart))
                sqlite3_bind_int64(statement, 9, sqlite3_int64(comment.anchorEnd))
                bind(statement, 10, comment.anchorQuote)
                sqlite3_bind_double(statement, 11, comment.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(statement, 12, comment.updatedAt.timeIntervalSinceReferenceDate)
                if let resolvedAt = comment.resolvedAt {
                    sqlite3_bind_double(statement, 13, resolvedAt.timeIntervalSinceReferenceDate)
                } else {
                    sqlite3_bind_null(statement, 13)
                }
            }
            if try !artifactUsesSharedDatabase(comment.artifactID) {
                try markRecordChanged(entity: .artifactComment, logicalKey: comment.id, at: comment.updatedAt)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteArtifactCommentRecord(_ commentID: String) throws {
        try execBind("DELETE FROM artifact_comments WHERE id = ?") { statement in
            bind(statement, 1, commentID)
        }
        try markRecordDeleted(entity: .artifactComment, logicalKey: commentID)
    }

    func deleteArtifactCommentFromSync(_ commentID: String) throws {
        try withoutSyncTracking {
            try execBind("DELETE FROM artifact_comments WHERE id = ?") { statement in
                bind(statement, 1, commentID)
            }
            try clearPendingSyncChange(entity: .artifactComment, logicalKey: commentID)
        }
    }

    func saveArtifactCollaborationRecord(_ record: ArtifactCollaborationRecord) throws {
        try execBind("""
            INSERT INTO artifact_collaboration (
                artifact_id, database_scope, zone_name, owner_name,
                share_record_name, permission, is_owner, last_body_revision, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(artifact_id) DO UPDATE SET
                database_scope = excluded.database_scope,
                zone_name = excluded.zone_name,
                owner_name = excluded.owner_name,
                share_record_name = excluded.share_record_name,
                permission = excluded.permission,
                is_owner = excluded.is_owner,
                last_body_revision = excluded.last_body_revision,
                updated_at = excluded.updated_at
        """) { statement in
            bind(statement, 1, record.artifactID)
            bind(statement, 2, record.databaseScope.rawValue)
            bind(statement, 3, record.zoneName)
            bind(statement, 4, record.ownerName)
            bind(statement, 5, record.shareRecordName)
            bind(statement, 6, record.permission.rawValue)
            sqlite3_bind_int(statement, 7, record.isOwner ? 1 : 0)
            bind(statement, 8, record.lastBodyRevision)
            sqlite3_bind_double(statement, 9, record.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    func loadArtifactCollaborationRecord(
        _ artifactID: String
    ) throws -> ArtifactCollaborationRecord? {
        var record: ArtifactCollaborationRecord?
        try queryBind("""
            SELECT database_scope, zone_name, owner_name, share_record_name,
                   permission, is_owner, last_body_revision, updated_at
            FROM artifact_collaboration
            WHERE artifact_id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, artifactID)
        }) { statement in
            guard let scopeRaw = string(statement, 0),
                  let scope = ArtifactCollaborationRecord.DatabaseScope(rawValue: scopeRaw),
                  let zoneName = string(statement, 1),
                  let ownerName = string(statement, 2),
                  let permissionRaw = string(statement, 4),
                  let permission = ArtifactCollaborationRecord.Permission(rawValue: permissionRaw)
            else { return }
            record = ArtifactCollaborationRecord(
                artifactID: artifactID,
                databaseScope: scope,
                zoneName: zoneName,
                ownerName: ownerName,
                shareRecordName: string(statement, 3),
                permission: permission,
                isOwner: sqlite3_column_int(statement, 5) != 0,
                lastBodyRevision: string(statement, 6),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 7))
            )
        }
        return record
    }

    func loadSharedArtifactCollaborationRecords() throws -> [ArtifactCollaborationRecord] {
        var records: [ArtifactCollaborationRecord] = []
        var ids: [String] = []
        try query("""
            SELECT artifact_id FROM artifact_collaboration
            WHERE database_scope = 'shared'
            ORDER BY artifact_id
        """) { statement in
            if let id = string(statement, 0) { ids.append(id) }
        }
        for id in ids {
            if let record = try loadArtifactCollaborationRecord(id) { records.append(record) }
        }
        return records
    }

    func artifactUsesSharedDatabase(_ artifactID: String) throws -> Bool {
        try loadArtifactCollaborationRecord(artifactID)?.databaseScope == .shared
    }
}
