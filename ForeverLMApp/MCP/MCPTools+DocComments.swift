import Foundation

// MARK: - A page's comments over MCP
//
// `list_doc_comments`, `comment_on_doc`, `update_doc_comment` and
// `delete_doc_comment`: the page's Comments panel (docs/docs-design.md,
// "Comments"), so an assistant can read the learner's threads, answer one, or
// leave a note on a passage, as the panel does. A comment is a synced record
// (`artifact_comments`); an assistant's own comments are signed "Assistant"
// (`ArtifactCommentRecord.assistantAuthorRecordName`), never the learner, and the
// learner can delete them from the panel. A new thread stands on the words it
// quotes: the page marks the first place they occur and says "Original text
// unavailable" when they are not in it. A team's page takes no comments here,
// since a comment there is written as a member of the team.

extension MCPDataStore {

    /// The page's threads in the order of their passages: each thread's first
    /// comment, its replies oldest first, and whether it is resolved.
    func listDocComments(artifactID rawArtifactID: String, includeResolved: Bool = true) async throws -> String {
        let artifactID = rawArtifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifactID.isEmpty else { throw MCPError.invalidInput("doc_id is required. Use list_docs to find it.") }
        let snapshot = try await notebookFileStorage.artifactMarkdown(artifactID)
        let threads = ArtifactCommentThread.threads(from: try await notebookFileStorage.artifactComments(artifactID))
        let shown = includeResolved ? threads : threads.filter { !$0.isResolved }
        let formatter = KnowledgeStore.iso8601Formatter
        return try jsonString([
            "doc": artifactPayload(snapshot.artifact),
            "open_count": threads.filter { !$0.isResolved }.count,
            "resolved_count": threads.filter(\.isResolved).count,
            "threads": shown.map { thread -> [String: Any] in
                [
                    "comment_id": thread.id,
                    "quote": thread.root.anchorQuote,
                    "resolved": thread.isResolved,
                    "resolved_at": thread.root.resolvedAt.map { formatter.string(from: $0) as Any } ?? NSNull(),
                    "messages": thread.messages.map { comment -> [String: Any] in
                        [
                            "comment_id": comment.id,
                            "author": comment.authorDisplayName,
                            "by_assistant": comment.isByAssistant,
                            "body": comment.body,
                            "created_at": formatter.string(from: comment.createdAt),
                            "updated_at": formatter.string(from: comment.updatedAt),
                        ]
                    },
                ]
            },
            "guidance": "Each thread is a comment on the words in quote, with its replies. Pass a thread's comment_id as reply_to in comment_on_doc to answer it, update_doc_comment to resolve or reopen it, delete_doc_comment to remove a message or the thread.",
        ] as [String: Any])
    }

    /// A new thread on the words `quote`, or with `replyTo`, a reply in that
    /// comment's thread. Signed "Assistant".
    func commentOnDoc(
        artifactID rawArtifactID: String?,
        quote rawQuote: String?,
        body rawBody: String,
        replyTo rawReplyTo: String?
    ) async throws -> String {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MCPError.invalidInput("body is required: the comment's words.") }
        let replyTo = rawReplyTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !replyTo.isEmpty {
            let thread = try await commentThread(containing: replyTo)
            try await refuseTeamPage(thread.root.artifactID, doing: "comment_on_doc")
            let reply = try await notebookFileStorage.replyToArtifactComment(
                replyTo,
                authorRecordName: ArtifactCommentRecord.assistantAuthorRecordName,
                authorDisplayName: ArtifactCommentRecord.assistantAuthorDisplayName,
                body: body
            )
            return try jsonString([
                "comment_id": reply.id,
                "thread_id": thread.id,
                "doc_id": reply.artifactID,
                "guidance": "Replied in the thread on “\(thread.root.anchorQuote)”. The learner sees it in the page's Comments, signed Assistant.",
            ] as [String: Any])
        }
        let artifactID = rawArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !artifactID.isEmpty else { throw MCPError.invalidInput("doc_id is required for a new thread; pass reply_to to answer one.") }
        let quote = rawQuote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !quote.isEmpty else {
            throw MCPError.invalidInput("quote is required for a new thread: the exact words of the page the comment is about.")
        }
        guard quote.count <= Self.commentQuoteLimit else {
            throw MCPError.invalidInput("quote is at most \(Self.commentQuoteLimit) characters; quote the words the comment is about, not a whole section.")
        }
        try await refuseTeamPage(artifactID, doing: "comment_on_doc")
        // The place is found again from the words when the page opens; the
        // stored offsets are a hint the editor does not need here.
        let comment = try await notebookFileStorage.addArtifactComment(
            artifactID: artifactID,
            parentCommentID: nil,
            authorRecordName: ArtifactCommentRecord.assistantAuthorRecordName,
            authorDisplayName: ArtifactCommentRecord.assistantAuthorDisplayName,
            body: body,
            selection: ArtifactEditorSelection(text: quote, from: 0, to: 0)
        )
        return try jsonString([
            "comment_id": comment.id,
            "doc_id": artifactID,
            "guidance": "Started a thread on “\(quote)”, signed Assistant. The page marks the first place those words occur; if they are not in the page the thread says Original text unavailable.",
        ] as [String: Any])
    }

    /// A comment's words rewritten, or its thread resolved or reopened.
    func updateDocComment(commentID rawCommentID: String, body rawBody: String?, resolved: Bool?) async throws -> String {
        let commentID = rawCommentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentID.isEmpty else { throw MCPError.invalidInput("comment_id is required. Use list_doc_comments to find it.") }
        let body = rawBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body != nil || resolved != nil else { throw MCPError.invalidInput("Pass body, resolved, or both.") }
        let thread = try await commentThread(containing: commentID)
        try await refuseTeamPage(thread.root.artifactID, doing: "update_doc_comment")
        if let body {
            guard !body.isEmpty else { throw MCPError.invalidInput("body cannot be empty; delete_doc_comment removes a comment.") }
            try await notebookFileStorage.editArtifactComment(commentID, body: body)
        }
        if let resolved {
            try await notebookFileStorage.setArtifactCommentResolved(thread.id, resolved: resolved)
        }
        return try jsonString([
            "comment_id": commentID,
            "thread_id": thread.id,
            "resolved": resolved ?? thread.isResolved,
            "guidance": resolved == true
                ? "Resolved: the page no longer marks the passage, and the thread is under Resolved in Comments."
                : "Updated.",
        ] as [String: Any])
    }

    /// One comment out, its replies kept (the first reply carries the thread
    /// on when it was the thread's first comment), or the whole thread.
    func deleteDocComment(commentID rawCommentID: String, wholeThread: Bool) async throws -> String {
        let commentID = rawCommentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentID.isEmpty else { throw MCPError.invalidInput("comment_id is required. Use list_doc_comments to find it.") }
        let thread = try await commentThread(containing: commentID)
        try await refuseTeamPage(thread.root.artifactID, doing: "delete_doc_comment")
        if wholeThread {
            try await notebookFileStorage.deleteArtifactCommentThread(thread.id)
        } else {
            try await notebookFileStorage.deleteArtifactComment(commentID)
        }
        return try jsonString([
            "deleted": wholeThread ? thread.messages.map(\.id) : [commentID],
            "doc_id": thread.root.artifactID,
            "guidance": wholeThread
                ? "Deleted the thread and all its messages."
                : (commentID == thread.id && !thread.replies.isEmpty
                    ? "Deleted the comment; its replies remain, and the first reply now opens the thread."
                    : "Deleted the comment."),
        ] as [String: Any])
    }

    static let commentQuoteLimit = 1_000

    /// The thread a comment is in, read from its page.
    private func commentThread(containing commentID: String) async throws -> ArtifactCommentThread {
        guard let comment = try knowledgeStore().loadArtifactCommentForSync(commentID) else {
            throw MCPError.invalidInput("Comment not found: \(commentID). Use list_doc_comments to see a page's comments.")
        }
        let threads = ArtifactCommentThread.threads(from: try await notebookFileStorage.artifactComments(comment.artifactID))
        guard let thread = threads.first(where: { $0.messages.contains { $0.id == commentID } }) else {
            throw MCPError.invalidInput("Comment not found: \(commentID). Use list_doc_comments to see a page's comments.")
        }
        return thread
    }

    private func refuseTeamPage(_ artifactID: String, doing tool: String) async throws {
        let snapshot = try await notebookFileStorage.artifactMarkdown(artifactID)
        guard snapshot.artifact.teamID == nil else {
            throw MCPError.invalidInput("‘\(snapshot.artifact.title)’ is a team's page: \(tool) changes comments on the learner's own pages only, since a comment on a team's page is written as a member of the team. The learner can comment on it in the app.")
        }
    }
}
