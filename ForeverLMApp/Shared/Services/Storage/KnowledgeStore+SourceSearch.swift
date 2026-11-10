// KnowledgeStore: searching source content by text and keywords.
import Foundation
import SQLite3

extension KnowledgeStore {

    /// `restrictedTo` narrows the scan to an explicit set of sources, applied
    /// in SQL so a small pool gets its own results rather than whatever
    /// survives a corpus-wide `LIMIT`.
    func searchSourceContent(
        query: String,
        maxResults: Int,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) throws -> [String: Float] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty, maxResults > 0 else { return [:] }
        if let restrictedTo, restrictedTo.isEmpty { return [:] }

        // Analyzed rather than merely split on punctuation, so this fallback answers the
        // same way the full-text index does: "GDF15" and "GDF-15" both reduce to `gdf`
        // and `15`, and a body spelling it either way satisfies both queries. Without
        // this, the window while the index is behind silently changed which spelling
        // worked.
        let rawTerms = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .flatMap { SourceSearchEngine.alphanumericParts(in: $0) }
        let terms = rawTerms.filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [:] }

        let exactPredicate = "lower(content) LIKE ? ESCAPE '\\'"
        let termPredicate = terms
            .map { _ in "lower(content) LIKE ? ESCAPE '\\'" }
            .joined(separator: " AND ")
        let restriction = restrictedTo.map(Array.init) ?? []
        let restrictionClause = restriction.isEmpty
            ? ""
            : "\n  AND source_id IN (\(restriction.map { _ in "?" }.joined(separator: ", ")))"
        let sql = """
            SELECT source_id, content
            FROM source_content
            WHERE content IS NOT NULL
              AND content != ''
              AND (\(exactPredicate) OR (\(termPredicate)))\(restrictionClause)
            LIMIT ?
            """

        let baseRowLimit = min(max(maxResults * 8, maxResults), 800)
        let rowLimit = min(baseRowLimit + excludedSources.count, 800)
        var scores: [String: Float] = [:]
        try queryBind(sql, bind: { stmt in
            self.bind(stmt, 1, "%\(Self.escapedLikePattern(normalizedQuery))%")
            for (offset, term) in terms.enumerated() {
                self.bind(stmt, offset + 2, "%\(Self.escapedLikePattern(term))%")
            }
            var nextIndex = terms.count + 2
            for sourceID in restriction {
                self.bind(stmt, nextIndex, sourceID)
                nextIndex += 1
            }
            sqlite3_bind_int(stmt, Int32(nextIndex), Int32(rowLimit))
        }) { stmt in
            guard scores.count < maxResults else { return }
            guard let sourceId = self.string(stmt, 0),
                  let content = self.string(stmt, 1) else { return }
            guard !excludedSources.contains(sourceId) else { return }
            let searchable = content.lowercased()
            var score: Float = searchable.contains(normalizedQuery) ? 1.5 : 0
            let matchCount = terms.filter { searchable.contains($0) }.count
            score += Float(matchCount) / Float(terms.count)
            guard score > 0 else { return }
            scores[sourceId] = max(scores[sourceId] ?? 0, score)
        }

        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(maxResults)
            .reduce(into: [:]) { result, item in
                result[item.key] = item.value
            }
    }

    /// Every active source whose title, author, or body contains the keywords
    /// literally, with a mention count and a few passages for each.
    ///
    /// The scan reads the text rather than `source_fts`, because the index
    /// tokenizes and this search must not: the whole point is that `uncoupler`
    /// finds a body that says `uncouplers`. It takes two reads. The first lists
    /// the sources in scope, newest first, without their text, so nothing
    /// book-sized is ever sorted; the second reads each text by id, one row at
    /// a time, and drops it, so a library of book-length sources costs one
    /// source's text in memory rather than the corpus.
    ///
    /// The keywords are not in the SQL. Until 2026-09-26 a `LIKE` per keyword
    /// chose the rows and Swift counted in them, and the two disagreed: `LIKE`
    /// folds ASCII case only and compares the text's own characters, so `Δψ`,
    /// bound as `δψ`, found nothing in a chapter that says `Δψ` 58 times, and
    /// `Differential` missed the PDFs that extract `Diﬀerential` — while the
    /// count, which folds as Unicode does, found both whenever another keyword
    /// let the row in. `SourceKeywordSearch.Screen` now rules texts out from
    /// their bytes with the count's own folding, and the count decides.
    func sourcesContainingKeywords(
        _ keywords: [String],
        matchAll: Bool,
        maxSources: Int,
        snippetsPerSource: Int,
        restrictedTo: Set<String>? = nil,
        sourceTypes: [String] = [],
        excluding excludedSourceIDs: Set<String> = []
    ) throws -> (matches: [SourceKeywordMatch], truncated: Bool) {
        let terms = SourceKeywordSearch.normalized(keywords)
        guard !terms.isEmpty, maxSources > 0 else { return ([], false) }
        if let restrictedTo, restrictedTo.isEmpty { return ([], false) }
        let searchKeywords = terms.map(SourceKeywordSearch.Keyword.init)
        var screen = SourceKeywordSearch.Screen(searchKeywords)

        let restriction = restrictedTo.map(Array.init) ?? []
        let restrictionClause = restriction.isEmpty
            ? ""
            : " AND sp.id IN (\(restriction.map { _ in "?" }.joined(separator: ", ")))"
        let typeClause = sourceTypes.isEmpty
            ? ""
            : " AND sp.source_type IN (\(sourceTypes.map { _ in "?" }.joined(separator: ", ")))"
        // Hidden sources are searched like any other: hiding is visual only
        // (product owner, 2026-09-11), so a hidden episode or an orphaned course
        // lecture is still an answer. Archived sources are out by status.
        // `excludedSourceIDs` carries the knowledge policy (the sidebar families
        // the learner keeps away from AI), which depends on preferences the SQL
        // cannot see. There is no SQL LIMIT: the cap counts sources the caller
        // will actually see, so an excluded row cannot use up a page and make a
        // truncated answer claim more matches than it shows.
        let sql = """
            SELECT sp.id, sp.title, sp.source_type, sp.author,
                   COALESCE(sp.parent_group_title, sp.parent_group) AS group_name
            FROM source_projection sp
            WHERE sp.status = 'active'\(restrictionClause)\(typeClause)
            ORDER BY sp.date_added DESC
            """
        var candidates: [(id: String, title: String?, sourceType: String?, author: String?, groupName: String?)] = []
        try queryBind(sql, bind: { stmt in
            var index = 1
            for sourceID in restriction {
                self.bind(stmt, index, sourceID)
                index += 1
            }
            for sourceType in sourceTypes {
                self.bind(stmt, index, sourceType)
                index += 1
            }
        }) { stmt in
            guard let sourceID = self.string(stmt, 0), !excludedSourceIDs.contains(sourceID) else { return }
            candidates.append((sourceID, self.string(stmt, 1), self.string(stmt, 2), self.string(stmt, 3), self.string(stmt, 4)))
        }

        let contentSQL = "SELECT content FROM source_content WHERE source_id = ?"
        var contentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, contentSQL, -1, &contentStmt, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw KnowledgeStoreError.execFailed(contentSQL, msg)
        }
        defer { sqlite3_finalize(contentStmt) }

        var matches: [SourceKeywordMatch] = []
        var truncated = false
        for candidate in candidates {
            sqlite3_reset(contentStmt)
            bind(contentStmt, 1, candidate.id)
            let rc = sqlite3_step(contentStmt)
            guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed (\(rc))"
                throw KnowledgeStoreError.execFailed(contentSQL, msg)
            }
            // A source with no body row is still searched by title and author.
            let text = rc == SQLITE_ROW ? sqlite3_column_text(contentStmt, 0) : nil
            let byteCount = text == nil ? 0 : Int(sqlite3_column_bytes(contentStmt, 0))
            let title = candidate.title ?? ""
            let author = candidate.author ?? ""
            var possible = screen.mayContain(UnsafeRawBufferPointer(start: text, count: byteCount))
            for field in [title, author] {
                for (index, mayContain) in screen.mayContain(field).enumerated() where mayContain {
                    possible[index] = true
                }
            }
            let possibleKeywords = zip(searchKeywords, possible).filter(\.1).map(\.0)
            if possibleKeywords.isEmpty || (matchAll && possibleKeywords.count < searchKeywords.count) { continue }

            // Only now is the text worth a Swift string. Past the cap only
            // whether one more source matches is worth knowing, so one
            // mention of each keyword settles it.
            let content = text.map { String(decoding: UnsafeBufferPointer(start: $0, count: byteCount), as: UTF8.self) } ?? ""
            let counts = SourceKeywordSearch.counts(
                of: possibleKeywords,
                inFields: [title, author, content],
                countCeiling: matches.count < maxSources ? 500 : 1
            )
            guard !counts.isEmpty else { continue }
            if matchAll, counts.count < searchKeywords.count { continue }
            guard matches.count < maxSources else {
                truncated = true
                break
            }
            let matched = Set(counts.map(\.keyword))
            matches.append(SourceKeywordMatch(
                sourceID: candidate.id,
                title: candidate.title ?? "Untitled",
                sourceType: candidate.sourceType ?? "unknown",
                author: candidate.author,
                groupName: candidate.groupName,
                keywordCounts: counts,
                snippets: SourceKeywordSearch.snippets(
                    for: possibleKeywords.filter { matched.contains($0.text) },
                    in: content.isEmpty ? [title, author].joined(separator: "\n") : content,
                    limit: snippetsPerSource
                )
            ))
        }

        // Most mentions first: the sources the keyword is actually about lead,
        // and a passing mention sinks, without any ranking model in between.
        matches.sort { lhs, rhs in
            let left = lhs.totalMentions
            let right = rhs.totalMentions
            if left != right { return left > right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return (matches, truncated)
    }

}
