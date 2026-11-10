import Foundation

extension KnowledgeStore {
    /// The sources an ordinary chat discussed (`ChatSourceEvidence.discussedSourceIDs`): the
    /// one source it was opened on, then the sources its turns cite by in-app link, in the
    /// order they were first cited. A link token is resolved the way the chat resolves it
    /// (`resolveSourceID(forLinkToken:)`), and one that names no source is dropped. Whether
    /// a source is still active is the caller's question.
    func chatDiscussedSourceIDs(sessionID: String) throws -> [String] {
        let attached = try attachedSourceIDs(sessionID: sessionID)
        var tokens: [String] = []
        try queryBind("""
            SELECT question, user_answer, evaluation
            FROM review_exchanges
            WHERE session_id = ?
              AND (instr(COALESCE(question, ''), ?) > 0
                OR instr(COALESCE(user_answer, ''), ?) > 0
                OR instr(COALESCE(evaluation, ''), ?) > 0)
            ORDER BY sequence_number
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
            for index in 2...4 { bind(stmt, index, ChatSourceEvidence.sourceLinkMarker) }
        }) { stmt in
            tokens.append(contentsOf: ChatSourceEvidence.sourceLinkTokens(
                question: self.string(stmt, 0),
                userAnswer: self.string(stmt, 1),
                evaluation: self.string(stmt, 2)
            ))
        }
        var cited: [String] = []
        var resolvedByToken: [String: String?] = [:]
        for token in tokens {
            let resolved: String?
            if let known = resolvedByToken[token] {
                resolved = known
            } else {
                resolved = try resolveSourceID(forLinkToken: token)
                resolvedByToken[token] = resolved
            }
            if let resolved, !cited.contains(resolved) { cited.append(resolved) }
        }
        let discussed = ChatSourceEvidence.discussedSourceIDs(attached: attached, cited: cited)
        let openedOn = attached.filter { discussed.contains($0) && !cited.contains($0) }
        return openedOn + cited
    }

    private func attachedSourceIDs(sessionID: String) throws -> [String] {
        var attached: [String] = []
        try queryBind("SELECT source_id FROM review_session_sources WHERE session_id = ?", bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            if let id = self.string(stmt, 0) { attached.append(id) }
        }
        return attached
    }
}
