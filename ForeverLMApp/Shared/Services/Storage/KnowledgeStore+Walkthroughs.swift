import Foundation
import SQLite3

/// A paper's walkthrough in `source_walkthroughs` (schema 122), and an
/// animation's in `artifact_walkthroughs` (schema 124).
///
/// One row a paper, holding the steps as one JSON document beside the SHA-256
/// of the text they were written against. Reads answer only for a walkthrough
/// whose text the paper still carries, so a re-extracted PDF never shows a walk
/// through words that are no longer on its pages; the row stays until a new
/// walkthrough replaces it, the way the review guide's does.
extension KnowledgeStore {
    /// Whether `content` is the text a walkthrough fingerprinted `sha` was
    /// written against. A video's walk is written against its transcript alone
    /// (`PaperWalkthroughSubject.walkedText`), so capturing its slides, which
    /// appends a slide block to the stored content, leaves the walk current;
    /// every other source's walk is held to its whole text.
    static func walkthroughText(_ content: String, matches sha: String?) -> Bool {
        guard let sha else { return false }
        if PaperContentPreparationService.sha256(content) == sha { return true }
        let walked = PaperWalkthroughSubject.walkedText(of: content)
        return walked != content && PaperContentPreparationService.sha256(walked) == sha
    }

    /// The paper's walkthrough, when it has one that matches its current text.
    func loadPaperWalkthrough(_ sourceID: String) throws -> PaperWalkthrough? {
        var result: PaperWalkthrough?
        try queryBind("""
            SELECT w.source_sha256, w.walkthrough_json, w.walkthrough_version, sc.content
            FROM source_walkthroughs w
            JOIN sources s ON s.id = w.source_id
            LEFT JOIN source_content sc ON sc.source_id = w.source_id
            WHERE w.source_id = ?
              AND s.status = 'active'
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            guard let sourceSHA256 = self.string(stmt, 0),
                  let json = self.string(stmt, 1),
                  Int(sqlite3_column_int(stmt, 2)) == PaperWalkthrough.currentVersion else { return }
            if let content = self.string(stmt, 3),
               !Self.walkthroughText(content, matches: sourceSHA256) {
                return
            }
            guard let walkthrough = try? PaperWalkthroughCoding.walkthrough(fromJSON: json),
                  walkthrough.isUsable else { return }
            result = walkthrough
        }
        return result
    }

    /// The walkthrough status of each of `sourceIDs` that has a row: `ok` for a
    /// walkthrough written against the paper's current text, `stale` otherwise.
    /// Ids with no row are absent. The Planner marks a block's readings with
    /// this, and `get_day_plan` reports it, so one query answers a day.
    func paperWalkthroughStatuses(for sourceIDs: some Collection<String>) throws -> [String: PaperWalkthroughStatus] {
        let ids = Array(Set(sourceIDs))
        guard !ids.isEmpty else { return [:] }
        var statuses: [String: PaperWalkthroughStatus] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            try queryBind("""
                SELECT w.source_id, w.source_sha256, w.walkthrough_version, sc.content, s.status
                FROM source_walkthroughs w
                JOIN sources s ON s.id = w.source_id
                LEFT JOIN source_content sc ON sc.source_id = w.source_id
                WHERE w.source_id IN (\(placeholders))
            """, bind: { stmt in
                for (index, id) in chunk.enumerated() { self.bind(stmt, index + 1, id) }
            }) { stmt in
                guard let id = self.string(stmt, 0) else { return }
                let sha = self.string(stmt, 1)
                let version = Int(sqlite3_column_int(stmt, 2))
                let content = self.string(stmt, 3)
                let active = self.string(stmt, 4) == SourceStatus.active.rawValue
                let current = active
                    && version == PaperWalkthrough.currentVersion
                    && content.map { Self.walkthroughText($0, matches: sha) } == true
                statuses[id] = current ? .ok : .stale
            }
        }
        return statuses
    }

    /// Every active source's walkthrough as a notebook's Studio lists it,
    /// newest first, without the steps' words: title, counts, who wrote it,
    /// and whether it still matches the source's text. One query over the
    /// walkthrough table, which holds one row a source; the JSON of each row
    /// is read for its counts, and a row this build cannot read is left out.
    func paperWalkthroughSummaries() throws -> [PaperWalkthroughSummary] {
        try paperWalkthroughSummaries(where: "", binding: [])
    }

    /// The walkthroughs of `sourceIDs` alone, newest first, read the same
    /// way: a notebook's Studio decodes only its own sources' walks rather
    /// than every walk in the library. In chunks of 200 ids, as
    /// `paperWalkthroughStatuses(for:)` reads.
    func paperWalkthroughSummaries(forSources sourceIDs: some Collection<String>) throws -> [PaperWalkthroughSummary] {
        let ids = Array(Set(sourceIDs))
        guard !ids.isEmpty else { return [] }
        var summaries: [PaperWalkthroughSummary] = []
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            summaries += try paperWalkthroughSummaries(where: "AND w.source_id IN (\(placeholders))", binding: chunk)
        }
        return summaries.sorted { $0.generatedAt > $1.generatedAt }
    }

    /// The summaries' one query, narrowed by `clause` (empty, or an `AND …`
    /// whose placeholders `values` fill in order).
    private func paperWalkthroughSummaries(where clause: String, binding values: [String]) throws -> [PaperWalkthroughSummary] {
        var summaries: [PaperWalkthroughSummary] = []
        try queryBind("""
            SELECT w.source_id, w.source_sha256, w.walkthrough_json, w.walkthrough_version, w.generated_at, sc.content
            FROM source_walkthroughs w
            JOIN sources s ON s.id = w.source_id
            LEFT JOIN source_content sc ON sc.source_id = w.source_id
            WHERE s.status = 'active' \(clause)
            ORDER BY w.generated_at DESC
        """, bind: { stmt in
            for (index, value) in values.enumerated() { self.bind(stmt, index + 1, value) }
        }) { stmt in
            guard let sourceID = self.string(stmt, 0),
                  let sha = self.string(stmt, 1),
                  let json = self.string(stmt, 2),
                  Int(sqlite3_column_int(stmt, 3)) == PaperWalkthrough.currentVersion,
                  let walkthrough = try? PaperWalkthroughCoding.walkthrough(fromJSON: json),
                  walkthrough.isUsable else { return }
            let current = self.string(stmt, 5).map { Self.walkthroughText($0, matches: sha) } == true
            summaries.append(PaperWalkthroughSummary(
                sourceID: sourceID,
                title: walkthrough.title,
                stepCount: walkthrough.steps.count,
                chapterCount: walkthrough.chapterCount,
                cardCount: walkthrough.cardCount,
                questionCount: walkthrough.quizCount,
                figureStepCount: walkthrough.figureStepCount,
                animationCount: walkthrough.animationCount,
                generatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                author: walkthrough.author,
                status: current ? .ok : .stale
            ))
        }
        return summaries
    }

    /// Whether the paper has a walkthrough row at all, whatever text it was
    /// written for. The Reader's button asks this, so a stale walkthrough still
    /// reads as "regenerate" rather than "generate".
    func hasPaperWalkthroughRow(_ sourceID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM source_walkthroughs WHERE source_id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { _ in found = true }
        return found
    }

    /// Saves the walkthrough and queues the source for sync. The record's
    /// `sourceSHA256` must be the paper's current text — a walkthrough written
    /// against text the paper no longer carries is refused rather than stored
    /// invisibly.
    func savePaperWalkthrough(_ walkthrough: PaperWalkthrough) throws {
        guard walkthrough.isUsable else {
            throw KnowledgeStoreError.invalidData("The walkthrough has no steps to save.")
        }
        guard try loadSourceForSync(walkthrough.sourceID) != nil else {
            throw KnowledgeStoreError.invalidData("Source \(walkthrough.sourceID) was not found.")
        }
        if let content = try loadSourceContent(walkthrough.sourceID),
           !Self.walkthroughText(content, matches: walkthrough.sourceSHA256) {
            throw KnowledgeStoreError.invalidData(
                "The paper's text changed while its walkthrough was being written; write it again."
            )
        }
        let json = try PaperWalkthroughCoding.json(walkthrough)
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertPaperWalkthrough(walkthrough, json: json)
            try queuePublishedSourceFilesRefresh(sourceID: walkthrough.sourceID)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Removes the paper's walkthrough and queues the source for sync, so the
    /// other Macs drop theirs too.
    @discardableResult
    func deletePaperWalkthrough(_ sourceID: String) throws -> Bool {
        guard try hasPaperWalkthroughRow(sourceID) else { return false }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM source_walkthroughs WHERE source_id = ?") { stmt in
                self.bind(stmt, 1, sourceID)
            }
            noteStoreChanged()
            try deleteWalkthroughProgress(sourceID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return true
    }

    // MARK: The pictures a walk shows

    private func upsertPaperWalkthrough(_ walkthrough: PaperWalkthrough, json: String) throws {
        try execBind("""
            INSERT INTO source_walkthroughs
                (source_id, source_sha256, walkthrough_json, walkthrough_version, generated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                source_sha256 = excluded.source_sha256,
                walkthrough_json = excluded.walkthrough_json,
                walkthrough_version = excluded.walkthrough_version,
                generated_at = excluded.generated_at
        """) { stmt in
            bind(stmt, 1, walkthrough.sourceID)
            bind(stmt, 2, walkthrough.sourceSHA256)
            bind(stmt, 3, json)
            sqlite3_bind_int(stmt, 4, Int32(walkthrough.version))
            sqlite3_bind_double(stmt, 5, walkthrough.generatedAt.timeIntervalSinceReferenceDate)
        }
    }

    // MARK: Animation walkthroughs (artifact_walkthroughs, schema 124)

    /// The animation's walkthrough, when it has one for its current address.
    /// The row's fingerprint is the animation's address digested
    /// (`PaperWalkthrough.animationFingerprint`), so a walk saved for one
    /// address is not shown against another; a republish of the same page
    /// keeps it, since the steps it names are the page's own.
    func loadArtifactWalkthrough(_ artifactID: String) throws -> PaperWalkthrough? {
        var result: PaperWalkthrough?
        try queryBind("""
            SELECT w.artifact_sha256, w.walkthrough_json, w.walkthrough_version, a.linked_url
            FROM artifact_walkthroughs w
            JOIN global_artifacts a ON a.id = w.artifact_id
            WHERE w.artifact_id = ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, artifactID)
        }) { stmt in
            guard let fingerprint = self.string(stmt, 0),
                  let json = self.string(stmt, 1),
                  Int(sqlite3_column_int(stmt, 2)) == PaperWalkthrough.currentVersion else { return }
            let linkedURL = self.string(stmt, 3)
            guard PaperWalkthrough.animationFingerprint(linkedURL: linkedURL, artifactID: artifactID) == fingerprint else { return }
            guard let walkthrough = try? PaperWalkthroughCoding.walkthrough(fromJSON: json),
                  walkthrough.isUsable, walkthrough.subject == .animation else { return }
            result = walkthrough
        }
        return result
    }

    /// Whether the animation has a walkthrough row at all, current or stale.
    func hasArtifactWalkthroughRow(_ artifactID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM artifact_walkthroughs WHERE artifact_id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, artifactID)
        }) { _ in found = true }
        return found
    }

    /// Every artifact with a walkthrough row, current or stale: what the
    /// Animations list reads to offer Walk Through, in one query.
    func artifactIDsWithWalkthroughs() throws -> Set<String> {
        var ids = Set<String>()
        try query("SELECT artifact_id FROM artifact_walkthroughs") { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    /// Saves an animation's walkthrough and queues the artifact for sync. The
    /// record is an animation walk (`subject == .animation`) whose
    /// `sourceID` is the artifact's id and whose `sourceSHA256` is the
    /// animation's current fingerprint; anything else is refused.
    func saveArtifactWalkthrough(_ walkthrough: PaperWalkthrough) throws {
        guard walkthrough.isUsable else {
            throw KnowledgeStoreError.invalidData("The walkthrough has no steps to save.")
        }
        guard walkthrough.subject == .animation else {
            throw KnowledgeStoreError.invalidData("Only an animation walk is saved on an artifact.")
        }
        guard let artifact = try loadArtifact(walkthrough.sourceID) else {
            throw KnowledgeStoreError.invalidData("Animation \(walkthrough.sourceID) was not found.")
        }
        guard artifact.isAnimation else {
            throw KnowledgeStoreError.invalidData("\"\(artifact.title)\" is not an animation.")
        }
        guard PaperWalkthrough.animationFingerprint(linkedURL: artifact.linkedURL, artifactID: artifact.id) == walkthrough.sourceSHA256 else {
            throw KnowledgeStoreError.invalidData("The animation's address changed while its walkthrough was being written; write it again.")
        }
        let json = try PaperWalkthroughCoding.json(walkthrough)
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertArtifactWalkthrough(walkthrough, json: json)
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Removes the animation's walkthrough and queues the artifact for sync.
    @discardableResult
    func deleteArtifactWalkthrough(_ artifactID: String) throws -> Bool {
        guard try hasArtifactWalkthroughRow(artifactID) else { return false }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM artifact_walkthroughs WHERE artifact_id = ?") { stmt in
                self.bind(stmt, 1, artifactID)
            }
            noteStoreChanged()
            try deleteWalkthroughProgress(artifactID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return true
    }

    private func upsertArtifactWalkthrough(_ walkthrough: PaperWalkthrough, json: String) throws {
        try execBind("""
            INSERT INTO artifact_walkthroughs
                (artifact_id, artifact_sha256, walkthrough_json, walkthrough_version, generated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(artifact_id) DO UPDATE SET
                artifact_sha256 = excluded.artifact_sha256,
                walkthrough_json = excluded.walkthrough_json,
                walkthrough_version = excluded.walkthrough_version,
                generated_at = excluded.generated_at
        """) { stmt in
            bind(stmt, 1, walkthrough.sourceID)
            bind(stmt, 2, walkthrough.sourceSHA256)
            bind(stmt, 3, json)
            sqlite3_bind_int(stmt, 4, Int32(walkthrough.version))
            sqlite3_bind_double(stmt, 5, walkthrough.generatedAt.timeIntervalSinceReferenceDate)
        }
    }
}

// MARK: Walkthrough progress (walkthrough_progress, schema 133)

extension KnowledgeStore {
    func loadWalkthroughProgress(_ subjectID: String) throws -> WalkthroughProgress? {
        // Generation 2 keys a source's walk by its wire id, so a team copy and the personal one share it.
        let key = try perMemberKey(subjectID)
        var result: WalkthroughProgress?
        try queryBind("SELECT progress_json FROM walkthrough_progress WHERE subject_id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, key)
        }) { stmt in
            guard let json = self.string(stmt, 0), let data = json.data(using: .utf8) else { return }
            result = try? JSONDecoder().decode(WalkthroughProgress.self, from: data)
        }
        return result
    }

    /// Saves where the learner is in a walk and queues it for the other Macs.
    func saveWalkthroughProgress(_ progress: WalkthroughProgress) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try writeWalkthroughProgressRow(progress)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Drops a walk's progress with the walk, and tells the other Macs.
    func deleteWalkthroughProgress(_ subjectID: String) throws {
        guard try hasWalkthroughProgress(subjectID) else { return }
        let key = try perMemberKey(subjectID)
        try execBind("DELETE FROM walkthrough_progress WHERE subject_id = ?") { stmt in
            self.bind(stmt, 1, key)
        }
    }

    func hasWalkthroughProgress(_ subjectID: String) throws -> Bool {
        let key = try perMemberKey(subjectID)
        var found = false
        try queryBind("SELECT 1 FROM walkthrough_progress WHERE subject_id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, key)
        }) { _ in
            found = true
        }
        return found
    }

    private func writeWalkthroughProgressRow(_ progress: WalkthroughProgress) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(progress), encoding: .utf8) else {
            throw KnowledgeStoreError.invalidData("Walkthrough progress for \(progress.subjectID) could not be encoded.")
        }
        let key = try perMemberKey(progress.subjectID)
        try execBind("""
            INSERT INTO walkthrough_progress (subject_id, progress_json, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(subject_id) DO UPDATE SET
                progress_json = excluded.progress_json,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, json)
            sqlite3_bind_double(stmt, 3, progress.updatedAt.timeIntervalSinceReferenceDate)
        }
    }
}
