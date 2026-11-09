import Foundation
import SQLite3

/// Understanding documents: the index row in SQLite, the prose on disk.
///
/// Every read resolves the stored relative path against each known content root,
/// so a library that has moved between iCloud Drive and local storage keeps
/// finding its documents. Writes always land in the current write root.
extension KnowledgeStore {

    // MARK: - Paths

    /// Where new documents are written. iCloud Drive when it exists, otherwise
    /// the ordinary local content root — an offline or signed-out Mac still gets
    /// a working companion, it just does not sync until iCloud Drive appears.
    /// Test-only redirect. Understanding documents are the one thing this store
    /// writes outside its own container, so a test that did not redirect them
    /// would drop files into the learner's real iCloud Drive.
    nonisolated(unsafe) static var understandingRootOverride: String?

    static func understandingWriteRoot() -> String {
        if let understandingRootOverride { return understandingRootOverride }
        let cloud = StorageService.cloudDocsContentRootPath
        var isDirectory: ObjCBool = false
        let parent = (cloud as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue {
            return cloud
        }
        return StorageService.libraryRootPath
    }

    static func understandingReadRoots() -> [String] {
        if let understandingRootOverride { return [understandingRootOverride] }
        var roots = [understandingWriteRoot()]
        for root in StorageService.knownContentRoots where !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }

    /// First existing file for this relative path across every root.
    static func resolveUnderstandingPath(_ relativePath: String) -> String? {
        for root in understandingReadRoots() {
            let candidate = (root as NSString).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Index

    func loadUnderstandingIndex(sourceID: String) throws -> UnderstandingIndexEntry? {
        // Generation 2 keys the row by the source's wire id, so a team copy reads the personal one's.
        let key = try perMemberKey(sourceID)
        var entry: UnderstandingIndexEntry?
        try queryBind("""
            SELECT source_id, relative_path, derived_through_session_id,
                   generated_at, generator_version, body_sha256, open_thread_count,
                   discussed_idea_ids
            FROM source_understanding
            WHERE source_id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, key)
        }) { stmt in
            entry = self.readUnderstandingIndexRow(stmt, sourceID: sourceID)
        }
        return entry
    }

    func loadUnderstandingIndex(sourceIDs: [String]) throws -> [String: UnderstandingIndexEntry] {
        // The callers' ids by the key each row is stored under (generation 2: the wire id).
        var callers: [String: [String]] = [:]
        for id in Set(sourceIDs) { callers[try perMemberKey(id), default: []].append(id) }
        let ids = callers.keys.sorted()
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var result: [String: UnderstandingIndexEntry] = [:]
        try queryBind("""
            SELECT source_id, relative_path, derived_through_session_id,
                   generated_at, generator_version, body_sha256, open_thread_count,
                   discussed_idea_ids
            FROM source_understanding
            WHERE source_id IN (\(placeholders))
        """, bind: { stmt in
            for (index, id) in ids.enumerated() { bind(stmt, index + 1, id) }
        }) { stmt in
            guard let key = self.string(stmt, 0) else { return }
            for id in callers[key] ?? [key] {
                if let entry = self.readUnderstandingIndexRow(stmt, sourceID: id) { result[id] = entry }
            }
        }
        return result
    }

    /// One index row, named by the caller's source id (the row's key may be its wire id).
    private func readUnderstandingIndexRow(_ stmt: OpaquePointer?, sourceID: String) -> UnderstandingIndexEntry? {
        guard string(stmt, 0) != nil, let path = string(stmt, 1) else { return nil }
        return UnderstandingIndexEntry(
            sourceID: sourceID,
            relativePath: path,
            derivedThroughSessionID: string(stmt, 2),
            generatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            generatorVersion: Int(sqlite3_column_int64(stmt, 4)),
            bodySHA256: string(stmt, 5) ?? "",
            openThreadCount: Int(sqlite3_column_int64(stmt, 6)),
            discussedIdeaIDs: Self.decodeDiscussedIdeaIDs(string(stmt, 7))
        )
    }

    /// The stored id list. Malformed JSON reads as empty — "nothing known",
    /// which leaves the review asking about the whole source rather than
    /// narrowing it to a set nobody can vouch for.
    static func decodeDiscussedIdeaIDs(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encodeDiscussedIdeaIDs(_ ids: [String]) -> String {
        guard !ids.isEmpty, let data = try? JSONEncoder().encode(ids) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Sources carrying unresolved threads. The cohort's "unfinished business"
    /// set, answered from the index so no file is opened to build it.
    func unfinishedUnderstandingSourceIDs() throws -> [String] {
        var ids: [String] = []
        // Under generation 2 the index is keyed by the source's wire id; the callers want the local row's
        // id (the personal copy first when a team's copy shares the wire id).
        try query("""
            SELECT COALESCE((
                       SELECT s.id FROM sources s WHERE s.id = su.source_id OR s.wire_key = su.source_id
                       ORDER BY (s.id = su.source_id) DESC, (s.team_id IS NULL) DESC, s.id LIMIT 1
                   ), su.source_id)
            FROM source_understanding su
            WHERE su.open_thread_count > 0
            ORDER BY su.open_thread_count DESC, su.source_id
        """) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    // MARK: - Documents

    /// The document as it exists on disk right now, which may include the
    /// learner's own edits. Returns nil when no document has been written yet;
    /// a row whose file has gone missing is also nil rather than an error, since
    /// the body is regenerable and a missing file simply means "write a new one".
    func loadUnderstandingDocument(sourceID: String) throws -> UnderstandingDocument? {
        guard let entry = try loadUnderstandingIndex(sourceID: sourceID) else { return nil }
        guard let absolute = Self.resolveUnderstandingPath(entry.relativePath),
              let markdown = try? String(contentsOfFile: absolute, encoding: .utf8) else {
            return nil
        }
        return UnderstandingDocument(
            sourceID: entry.sourceID,
            relativePath: entry.relativePath,
            markdown: markdown,
            derivedThroughSessionID: entry.derivedThroughSessionID,
            generatedAt: entry.generatedAt,
            generatorVersion: entry.generatorVersion,
            bodySHA256: entry.bodySHA256,
            openThreadCount: entry.openThreadCount,
            discussedIdeaIDs: entry.discussedIdeaIDs
        )
    }

    func loadUnderstandingDocuments(sourceIDs: [String]) throws -> [String: UnderstandingDocument] {
        var out: [String: UnderstandingDocument] = [:]
        for (sourceID, _) in try loadUnderstandingIndex(sourceIDs: sourceIDs) {
            if let document = try loadUnderstandingDocument(sourceID: sourceID) {
                out[sourceID] = document
            }
        }
        return out
    }

    /// Writes the prose and records what was written.
    ///
    /// The relative path is allocated once and then reused forever: a retitled
    /// source keeps its file rather than stranding the old one. The digest is of
    /// exactly the bytes written, so any later difference is a learner edit.
    @discardableResult
    func saveUnderstandingDocument(
        sourceID: String,
        title: String,
        markdown: String,
        derivedThroughSessionID: String?,
        openThreadCount: Int = 0,
        discussedIdeaIDs: [String]? = nil,
        now: Date = Date()
    ) throws -> UnderstandingDocument {
        let existing = try loadUnderstandingIndex(sourceID: sourceID)
        // A close that says nothing about ideas — an older prompt, a model that
        // omitted the field — must not erase what an earlier one recorded.
        // Passing an explicit empty list does clear it: that is a close saying
        // the conversation engaged nothing.
        let discussed = discussedIdeaIDs ?? existing?.discussedIdeaIDs ?? []
        let relativePath: String
        if let existing {
            relativePath = existing.relativePath
        } else {
            relativePath = UnderstandingDocumentPaths.relativePath(
                title: title,
                portableSourceKey: try portableMemorySourceKey(sourceID: sourceID)
            )
        }

        // A rewrite (the review's closer, the day close, an assistant's
        // record_understanding) returns the whole document; the learner's Think
        // first takes are theirs, so any the rewrite left out go back in at the
        // end, as they were (`ThinkFirstTake.keepingTakes`).
        let previous = existing.flatMap { Self.resolveUnderstandingPath($0.relativePath) }
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let written = ThinkFirstTake.keepingTakes(of: previous, in: markdown)

        let root = Self.understandingWriteRoot()
        let absolute = (root as NSString).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            atPath: (absolute as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try written.write(toFile: absolute, atomically: true, encoding: .utf8)

        let digest = UnderstandingDocument.digest(written)
        let key = try perMemberKey(sourceID)
        try execBind("""
            INSERT INTO source_understanding (
                source_id, relative_path, derived_through_session_id,
                generated_at, generator_version, body_sha256, open_thread_count,
                discussed_idea_ids
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                relative_path = excluded.relative_path,
                derived_through_session_id = excluded.derived_through_session_id,
                generated_at = excluded.generated_at,
                generator_version = excluded.generator_version,
                body_sha256 = excluded.body_sha256,
                open_thread_count = excluded.open_thread_count,
                discussed_idea_ids = excluded.discussed_idea_ids
        """) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, relativePath)
            bind(stmt, 3, derivedThroughSessionID)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 5, Int64(UnderstandingDocument.currentGeneratorVersion))
            bind(stmt, 6, digest)
            sqlite3_bind_int64(stmt, 7, Int64(max(0, openThreadCount)))
            bind(stmt, 8, Self.encodeDiscussedIdeaIDs(discussed))
        }
        // Generation 2: the new body is laid out again as the ReadingState's `understanding` satellite.
        try execute("""
            INSERT INTO ck_backfill_queue (kind, target, enqueued_at) VALUES (?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET attempts = 0, last_error = NULL
        """, [.text(Self.understandingBackfillKind), .text(key), .real(now.timeIntervalSinceReferenceDate)])

        return UnderstandingDocument(
            sourceID: sourceID,
            relativePath: relativePath,
            markdown: written,
            derivedThroughSessionID: derivedThroughSessionID,
            generatedAt: now,
            generatorVersion: UnderstandingDocument.currentGeneratorVersion,
            bodySHA256: digest,
            openThreadCount: max(0, openThreadCount),
            discussedIdeaIDs: discussed
        )
    }

    // MARK: - Think first takes

    /// Adds a take the learner wrote before ForeverLM showed its summary of
    /// the source (docs/fences-and-think-first-design.md, "Think first") to
    /// the end of the source's understanding document, under a dated
    /// "Before the summary" heading (`ThinkFirstTake`). A source with no
    /// document gets one: the blank header, then the take.
    ///
    /// The index row's digest stays what the model last wrote (for a new
    /// document, the blank header's), so the take reads as what it is, the
    /// learner's own words: the closer is told to keep hand edits, and
    /// `saveUnderstandingDocument` puts back any take a rewrite drops.
    @discardableResult
    func appendThinkFirstTake(
        sourceID: String,
        title: String,
        question: String,
        take: String,
        now: Date = Date()
    ) throws -> UnderstandingDocument {
        let entry = try loadUnderstandingIndex(sourceID: sourceID)
        let document = try loadUnderstandingDocument(sourceID: sourceID)
        let base = document?.markdown ?? UnderstandingDocumentTemplate.blank(title: title)
        let section = ThinkFirstTake.section(question: question, take: take, on: now)
        let markdown = base.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section + "\n"
        let relativePath: String
        if let entry {
            relativePath = entry.relativePath
        } else {
            relativePath = UnderstandingDocumentPaths.relativePath(
                title: title,
                portableSourceKey: try portableMemorySourceKey(sourceID: sourceID)
            )
        }

        let root = Self.understandingWriteRoot()
        let absolute = (root as NSString).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            atPath: (absolute as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try markdown.write(toFile: absolute, atomically: true, encoding: .utf8)

        // What the model last wrote: the row's digest while its file was
        // there, else the blank header this take now follows.
        let digest = document?.bodySHA256 ?? UnderstandingDocument.digest(base)
        let key = try perMemberKey(sourceID)
        let generatedAt = entry?.generatedAt ?? now
        try execBind("""
            INSERT INTO source_understanding (
                source_id, relative_path, derived_through_session_id,
                generated_at, generator_version, body_sha256, open_thread_count,
                discussed_idea_ids
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET
                relative_path = excluded.relative_path,
                body_sha256 = excluded.body_sha256
        """) { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, relativePath)
            bind(stmt, 3, entry?.derivedThroughSessionID)
            sqlite3_bind_double(stmt, 4, generatedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 5, Int64(entry?.generatorVersion ?? UnderstandingDocument.currentGeneratorVersion))
            bind(stmt, 6, digest)
            sqlite3_bind_int64(stmt, 7, Int64(max(0, entry?.openThreadCount ?? 0)))
            bind(stmt, 8, Self.encodeDiscussedIdeaIDs(entry?.discussedIdeaIDs ?? []))
        }
        // Generation 2: the new body travels as the ReadingState's `understanding` satellite.
        try execute("""
            INSERT INTO ck_backfill_queue (kind, target, enqueued_at) VALUES (?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET attempts = 0, last_error = NULL
        """, [.text(Self.understandingBackfillKind), .text(key), .real(now.timeIntervalSinceReferenceDate)])

        return UnderstandingDocument(
            sourceID: sourceID,
            relativePath: relativePath,
            markdown: markdown,
            derivedThroughSessionID: entry?.derivedThroughSessionID,
            generatedAt: generatedAt,
            generatorVersion: entry?.generatorVersion ?? UnderstandingDocument.currentGeneratorVersion,
            bodySHA256: digest,
            openThreadCount: max(0, entry?.openThreadCount ?? 0),
            discussedIdeaIDs: entry?.discussedIdeaIDs ?? []
        )
    }

    // MARK: - Conflicts

    /// iCloud resolves a simultaneous edit on two Macs by leaving both files.
    ///
    /// There is no field-level merge to attempt on a paragraph of prose, so this
    /// only *finds* the copies; reconciling them is one LLM call at review time,
    /// and dropping one costs nothing permanent because the body is regenerable.
    func understandingConflictCopies(sourceID: String) throws -> [String] {
        guard let entry = try loadUnderstandingIndex(sourceID: sourceID) else { return [] }
        let canonicalName = (entry.relativePath as NSString).lastPathComponent
        let directory = (entry.relativePath as NSString).deletingLastPathComponent

        var found: [String] = []
        var seenNames = Set<String>()
        for root in Self.understandingReadRoots() {
            let absoluteDirectory = (root as NSString).appendingPathComponent(directory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: absoluteDirectory) else {
                continue
            }
            for name in names.sorted() where UnderstandingDocumentPaths.isConflictSibling(
                fileName: name,
                of: canonicalName
            ) {
                guard seenNames.insert(name).inserted else { continue }
                found.append((absoluteDirectory as NSString).appendingPathComponent(name))
            }
        }
        return found
    }

    /// Replaces the canonical document with reconciled prose and removes the
    /// copies that fed it. Deleting only after the canonical write succeeds means
    /// a failure here leaves every version still on disk.
    func resolveUnderstandingConflicts(
        sourceID: String,
        title: String,
        reconciledMarkdown: String,
        conflictPaths: [String],
        derivedThroughSessionID: String?,
        openThreadCount: Int = 0,
        now: Date = Date()
    ) throws -> UnderstandingDocument {
        let document = try saveUnderstandingDocument(
            sourceID: sourceID,
            title: title,
            markdown: reconciledMarkdown,
            derivedThroughSessionID: derivedThroughSessionID,
            openThreadCount: openThreadCount,
            now: now
        )
        for path in conflictPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        return document
    }
}
