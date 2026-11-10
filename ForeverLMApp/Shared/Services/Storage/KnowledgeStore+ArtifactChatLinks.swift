// KnowledgeStore: the doc passages a chat was opened on.
import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Doc passages a chat was opened on

    /// Records that this conversation started on a passage of a doc.
    ///
    /// Idempotent by anchor: asking twice about the same words in the same chat
    /// refreshes the one row rather than stacking duplicates. A second passage,
    /// or the same passage after the doc has been revised, is a genuinely
    /// different anchor and gets its own row.
    ///
    /// The session is marked changed so the link reaches the other Mac inside
    /// the session record it belongs to.
    @discardableResult
    func linkArtifactPassageToChat(
        artifactID: String,
        sessionID: String,
        anchorRevision: String,
        anchorStart: Int,
        anchorEnd: Int,
        anchorQuote: String,
        sectionTitle: String,
        createdAt: Date = Date()
    ) throws -> ArtifactChatLinkRecord {
        let quote = anchorQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifactID.isEmpty, !sessionID.isEmpty, !quote.isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "A chat can only be linked to a passage that has a doc, a chat, and some words."
            )
        }
        let record = ArtifactChatLinkRecord(
            id: UUID().uuidString,
            artifactID: artifactID,
            sessionID: sessionID,
            anchorRevision: anchorRevision,
            anchorStart: max(0, anchorStart),
            anchorEnd: max(max(0, anchorStart), anchorEnd),
            anchorQuote: quote,
            sectionTitle: sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: createdAt
        )
        try execBind("""
            INSERT INTO artifact_chat_links (
                id, artifact_id, session_id, anchor_revision, anchor_start,
                anchor_end, anchor_quote, section_title, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, artifact_id, anchor_revision, anchor_start, anchor_end)
            DO UPDATE SET
                anchor_quote = excluded.anchor_quote,
                section_title = excluded.section_title
        """) { statement in
            bind(statement, 1, record.id)
            bind(statement, 2, record.artifactID)
            bind(statement, 3, record.sessionID)
            bind(statement, 4, record.anchorRevision)
            sqlite3_bind_int64(statement, 5, sqlite3_int64(record.anchorStart))
            sqlite3_bind_int64(statement, 6, sqlite3_int64(record.anchorEnd))
            bind(statement, 7, record.anchorQuote)
            bind(statement, 8, record.sectionTitle)
            sqlite3_bind_double(statement, 9, record.createdAt.timeIntervalSinceReferenceDate)
        }
        noteStoreChanged()
        return record
    }

    /// Every passage of this doc that has a conversation behind it, oldest first.
    func artifactChatLinks(artifactID: String) throws -> [ArtifactChatLinkRecord] {
        try artifactChatLinks(
            whereClause: "artifact_id = ?",
            bindValue: artifactID
        )
    }

    /// Every doc passage this chat was opened on, oldest first.
    func artifactChatLinks(sessionID: String) throws -> [ArtifactChatLinkRecord] {
        try artifactChatLinks(
            whereClause: "session_id = ?",
            bindValue: sessionID
        )
    }

    private func artifactChatLinks(
        whereClause: String,
        bindValue: String
    ) throws -> [ArtifactChatLinkRecord] {
        var links: [ArtifactChatLinkRecord] = []
        try queryBind("""
            SELECT id, artifact_id, session_id, anchor_revision, anchor_start,
                   anchor_end, anchor_quote, section_title, created_at
            FROM artifact_chat_links
            WHERE \(whereClause)
            ORDER BY created_at, id
        """, bind: { statement in
            bind(statement, 1, bindValue)
        }) { statement in
            guard let id = self.string(statement, 0),
                  let artifactID = self.string(statement, 1),
                  let sessionID = self.string(statement, 2),
                  let quote = self.string(statement, 6) else { return }
            links.append(ArtifactChatLinkRecord(
                id: id,
                artifactID: artifactID,
                sessionID: sessionID,
                anchorRevision: self.string(statement, 3) ?? "",
                anchorStart: Int(sqlite3_column_int64(statement, 4)),
                anchorEnd: Int(sqlite3_column_int64(statement, 5)),
                anchorQuote: quote,
                sectionTitle: self.string(statement, 7) ?? "",
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8))
            ))
        }
        return links
    }

    /// Forgets one passage-to-chat link. The conversation and the doc both
    /// survive it — this only says the two are no longer related.
    func deleteArtifactChatLink(_ linkID: String) throws {
        var sessionID: String?
        try queryBind(
            "SELECT session_id FROM artifact_chat_links WHERE id = ? LIMIT 1",
            bind: { statement in bind(statement, 1, linkID) }
        ) { statement in
            sessionID = self.string(statement, 0)
        }
        guard sessionID != nil else { return }
        try execBind("DELETE FROM artifact_chat_links WHERE id = ?") { statement in
            bind(statement, 1, linkID)
        }
        noteStoreChanged()
    }

    /// Drops the links a deleted doc leaves behind. `artifact_id` carries no
    /// foreign key — CloudKit may deliver a chat before its doc — so nothing
    /// sweeps these rows automatically.
    func deleteArtifactChatLinks(artifactID: String) throws {
        var sessionIDs: [String] = []
        try queryBind(
            "SELECT DISTINCT session_id FROM artifact_chat_links WHERE artifact_id = ?",
            bind: { statement in bind(statement, 1, artifactID) }
        ) { statement in
            if let id = self.string(statement, 0) { sessionIDs.append(id) }
        }
        guard !sessionIDs.isEmpty else { return }
        try execBind("DELETE FROM artifact_chat_links WHERE artifact_id = ?") { statement in
            bind(statement, 1, artifactID)
        }
        if !sessionIDs.isEmpty {
            noteStoreChanged()
        }
    }

    /// Replaces a session's links with what an inbound sync payload says they
    /// are. Called inside the session's own transaction, and never marks the
    /// session changed: doing so would bounce the record straight back out.
    func replaceArtifactChatLinks(
        sessionID: String,
        links: [CloudKitArtifactChatLinkPayload]
    ) throws {
        try execBind("DELETE FROM artifact_chat_links WHERE session_id = ?") { statement in
            bind(statement, 1, sessionID)
        }
        for link in links {
            let quote = link.anchorQuote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.artifactID.isEmpty, !quote.isEmpty else { continue }
            try execBind("""
                INSERT INTO artifact_chat_links (
                    id, artifact_id, session_id, anchor_revision, anchor_start,
                    anchor_end, anchor_quote, section_title, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, artifact_id, anchor_revision, anchor_start, anchor_end)
                DO UPDATE SET
                    anchor_quote = excluded.anchor_quote,
                    section_title = excluded.section_title
            """) { statement in
                bind(statement, 1, link.id)
                bind(statement, 2, link.artifactID)
                bind(statement, 3, sessionID)
                bind(statement, 4, link.anchorRevision)
                sqlite3_bind_int64(statement, 5, sqlite3_int64(max(0, link.anchorStart)))
                sqlite3_bind_int64(statement, 6, sqlite3_int64(max(0, link.anchorEnd)))
                bind(statement, 7, quote)
                bind(statement, 8, link.sectionTitle)
                sqlite3_bind_double(statement, 9, link.createdAt.timeIntervalSinceReferenceDate)
            }
        }
    }

}
