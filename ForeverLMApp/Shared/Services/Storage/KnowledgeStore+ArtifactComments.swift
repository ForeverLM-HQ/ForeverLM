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
    }

    /// A reply in a comment's thread: it stands on the thread's passage (the
    /// opening comment's anchor), and its parent is the thread's opening
    /// comment however deep the comment answered sits, as Codex keeps a thread
    /// one level deep.
    @discardableResult
    func replyToArtifactComment(
        _ commentID: String,
        id: String = UUID().uuidString.lowercased(),
        authorRecordName: String,
        authorDisplayName: String,
        body: String,
        at date: Date = Date()
    ) throws -> ArtifactCommentRecord {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard let answered = try loadArtifactCommentForSync(commentID) else { throw ArtifactCommentError.unavailable }
        let comments = try loadArtifactComments(answered.artifactID)
        let rootID = ArtifactCommentThread.rootID(of: answered, in: comments)
        guard let root = comments.first(where: { $0.id == rootID }) else { throw ArtifactCommentError.unavailable }
        let reply = ArtifactCommentRecord(
            id: id,
            artifactID: root.artifactID,
            parentCommentID: root.id,
            authorRecordName: authorRecordName,
            authorDisplayName: authorDisplayName,
            body: text,
            anchorRevision: root.anchorRevision,
            anchorStart: root.anchorStart,
            anchorEnd: root.anchorEnd,
            anchorQuote: root.anchorQuote,
            createdAt: date,
            updatedAt: date,
            resolvedAt: nil
        )
        try saveArtifactCommentRecord(reply)
        return reply
    }

    /// A comment's words, rewritten by its author (Codex's Edit comment).
    @discardableResult
    func editArtifactComment(_ commentID: String, body: String, at date: Date = Date()) throws -> ArtifactCommentRecord {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard var comment = try loadArtifactCommentForSync(commentID) else { throw ArtifactCommentError.unavailable }
        guard comment.body != text else { return comment }
        comment.body = text
        comment.updatedAt = date
        try saveArtifactCommentRecord(comment)
        return comment
    }

    /// One comment taken out, its replies kept (Codex's Delete comment: "The
    /// comment text will be removed, but replies will remain"). Deleting the
    /// comment that opened a thread hands the thread to its first reply, which
    /// already stands on the same passage, so the rest of the conversation and
    /// its place on the page survive.
    func deleteArtifactComment(_ commentID: String, at date: Date = Date()) throws {
        guard let comment = try loadArtifactCommentForSync(commentID) else { throw ArtifactCommentError.unavailable }
        let comments = try loadArtifactComments(comment.artifactID)
        let replies = comments
            .filter { $0.parentCommentID == comment.id }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if let heir = replies.first {
            for reply in replies {
                let promoted = ArtifactCommentRecord(
                    id: reply.id,
                    artifactID: reply.artifactID,
                    parentCommentID: reply.id == heir.id ? comment.parentCommentID : heir.id,
                    authorRecordName: reply.authorRecordName,
                    authorDisplayName: reply.authorDisplayName,
                    body: reply.body,
                    anchorRevision: comment.anchorRevision,
                    anchorStart: comment.anchorStart,
                    anchorEnd: comment.anchorEnd,
                    anchorQuote: comment.anchorQuote,
                    createdAt: reply.createdAt,
                    updatedAt: date,
                    // The thread keeps whether it was resolved.
                    resolvedAt: reply.id == heir.id ? comment.resolvedAt : reply.resolvedAt
                )
                try saveArtifactCommentRecord(promoted)
            }
        }
        try deleteArtifactCommentRecord(comment.id)
    }

    /// A whole thread taken out: the comment that opened it and every reply
    /// (Codex's Delete thread: "This removes the thread and all its messages").
    func deleteArtifactCommentThread(_ commentID: String) throws {
        guard let comment = try loadArtifactCommentForSync(commentID) else { throw ArtifactCommentError.unavailable }
        let comments = try loadArtifactComments(comment.artifactID)
        let rootID = ArtifactCommentThread.rootID(of: comment, in: comments)
        // Replies before the comment they answer, each deletion recorded for
        // sync: the table's cascade would take them silently.
        let members = comments.filter { ArtifactCommentThread.rootID(of: $0, in: comments) == rootID }
        for member in members where member.id != rootID {
            try deleteArtifactCommentRecord(member.id)
        }
        try deleteArtifactCommentRecord(rootID)
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

    func artifactUsesSharedDatabase(_ artifactID: String) throws -> Bool {
        try loadArtifactCollaborationRecord(artifactID)?.databaseScope == .shared
    }
}
