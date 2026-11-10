import Foundation

// MARK: - Soft hyphens left in stored text (schema 166)
//
// docs/source-content-integrity.md, "Soft hyphens are not text", and
// docs/backend-storage-sync.md, "Soft hyphens repaired (schema version 166)".
// Builds before 166 kept U+00AD SOFT HYPHEN in the text they derived — a
// publisher's PDF puts one after a hyphen at a line end, a web page writes
// `&shy;` — and three articles held the literal `&shy;`, which the decoder did
// not know. The producers drop them now; this repairs what they stored before.

/// What a soft hyphen older builds stored becomes: nothing.
enum StoredSoftHyphens {
    /// The entity a decoder without `shy` left in stored text as written.
    static let entity = "&shy;"

    /// Whether `text` holds a soft hyphen or the literal entity.
    static func holdsSoftHyphen(_ text: String) -> Bool {
        text.unicodeScalars.contains("\u{00AD}") || text.contains(entity)
    }

    /// `text` with every U+00AD dropped, and every literal `&shy;` that touches a
    /// letter or a digit — the undecoded entity inside a word, after a word's
    /// hyphen ("regeneration-&shy;associated") or before its punctuation — dropped
    /// too. A `&shy;` with neither beside it is a page writing about the entity and
    /// stays. Words are never joined: what is dropped is only ever the hint.
    static func repaired(_ text: String) -> String {
        guard holdsSoftHyphen(text) else { return text }
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        kept.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{00AD}" {
                index += 1
                continue
            }
            if startsEntity(scalars, at: index) {
                let end = index + entityScalars.count
                if isWordScalar(kept.last) || isWordScalar(firstKeptScalar(scalars, from: end)) {
                    index = end
                    continue
                }
            }
            kept.append(scalar)
            index += 1
        }
        return String(kept)
    }

    private static let entityScalars = Array(entity.unicodeScalars)

    private static func startsEntity(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard scalars[index] == "&", index + entityScalars.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + entityScalars.count)]) == entityScalars
    }

    /// The first scalar from `index` on that is neither a soft hyphen nor the
    /// entity: what a run of them stands before.
    private static func firstKeptScalar(_ scalars: [Unicode.Scalar], from index: Int) -> Unicode.Scalar? {
        var index = index
        while index < scalars.count {
            if scalars[index] == "\u{00AD}" {
                index += 1
            } else if startsEntity(scalars, at: index) {
                index += entityScalars.count
            } else {
                return scalars[index]
            }
        }
        return nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Stages one source for the repair, by id, when the text this Mac now
    /// holds for it has a soft hyphen: text another Mac's older build published
    /// (`InboundSourceFiles.receivedText`). The next drain repairs it with the
    /// rest. Nothing happens on a store without the queue.
    static func stage(sourceID: String, holding text: String, connection: SQLiteConnection) throws {
        guard holdsSoftHyphen(text),
              try connection.scalarInteger(
                  "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                  [.text(KnowledgeStore.storedSoftHyphenRepairQueue)]
              ) == 1 else { return }
        try connection.execute("""
            INSERT INTO source_text_soft_hyphen_repair_queue (source_id, enqueued_at) VALUES (?, ?)
            ON CONFLICT(source_id) DO NOTHING
        """, [.text(sourceID), .real(Date().timeIntervalSinceReferenceDate)])
    }
}

/// One drain batch: how many queue rows it answered, and the sources whose
/// stored text, title or derived text it changed.
struct StoredSoftHyphenRepairBatch: Equatable, Sendable {
    var processedCount: Int
    var repairedSourceIDs: [String]

    static let empty = StoredSoftHyphenRepairBatch(processedCount: 0, repairedSourceIDs: [])
}

extension KnowledgeStore {
    static let storedSoftHyphenRepairQueue = "source_text_soft_hyphen_repair_queue"

    /// False on a store held at 153 for want of room for its rollback copy,
    /// which has not reached 166's queue yet: there is nothing to drain there.
    private func holdsStoredSoftHyphenRepairQueue() throws -> Bool {
        try scalarInteger(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(Self.storedSoftHyphenRepairQueue)]
        ) == 1
    }

    /// The next `limit` staged sources, each with whether any text it keeps
    /// holds a soft hyphen: the canonical text, a paper's or an article's raw
    /// extraction, a podcast transcript's input, the Listen text and the title.
    /// One `instr` scan of those columns per source; the clean ones never reach
    /// Swift. A source a paid pass is working on — the canonical clean-up, the
    /// podcast ad clean-up, the Listen preparation — is not read: each commits
    /// only over the text it started from, so a repair under it would make it
    /// fail and buy the same work again. It waits in the queue for a later drain.
    static let storedSoftHyphenBatchSQL = """
        SELECT q.source_id,
               EXISTS (SELECT 1 FROM source_content c WHERE c.source_id = q.source_id
                       AND (instr(c.content, char(173)) > 0 OR instr(c.content, '&shy;') > 0))
            OR EXISTS (SELECT 1 FROM paper_content_preparations p WHERE p.source_id = q.source_id
                       AND (instr(p.raw_content, char(173)) > 0 OR instr(p.raw_content, '&shy;') > 0))
            OR EXISTS (SELECT 1 FROM article_content_preparations a WHERE a.source_id = q.source_id
                       AND (instr(a.raw_content, char(173)) > 0 OR instr(a.raw_content, '&shy;') > 0))
            OR EXISTS (SELECT 1 FROM podcast_transcript_preparations t WHERE t.source_id = q.source_id
                       AND (instr(t.input_content, char(173)) > 0 OR instr(t.input_content, '&shy;') > 0))
            OR EXISTS (SELECT 1 FROM source_listenable_content l WHERE l.source_id = q.source_id
                       AND (instr(l.content, char(173)) > 0 OR instr(l.content, '&shy;') > 0))
            OR EXISTS (SELECT 1 FROM source_projection sp WHERE sp.id = q.source_id
                       AND (instr(sp.title, char(173)) > 0 OR instr(sp.title, '&shy;') > 0))
        FROM source_text_soft_hyphen_repair_queue q
        WHERE NOT EXISTS (SELECT 1 FROM canonical_content_cleanup_queue x WHERE x.source_id = q.source_id)
          AND NOT EXISTS (SELECT 1 FROM podcast_transcript_cleanup_queue x WHERE x.source_id = q.source_id)
          AND NOT EXISTS (SELECT 1 FROM source_listenable_content_queue x WHERE x.source_id = q.source_id)
        ORDER BY q.enqueued_at, q.source_id
        LIMIT ?
        """

    /// One bounded batch of the schema-166 repair: up to `limit` staged sources
    /// read, the clean ones out of the queue in one statement, and at most
    /// `repairs` of the others repaired, each in its own transaction
    /// (`repairStoredSoftHyphens`). A repair drops the source's full-text row and
    /// embeddings, which costs most of a tenth of a second on the largest library
    /// (a scan of the full-text table, and of the chunk vectors), so a batch
    /// repairs one source by default and the storage lane is never held long;
    /// the rest of its window is read again by the next batch. Idempotent and
    /// resumable: a repaired text holds none, so a second pass over it changes
    /// nothing, and a quit midway leaves the unanswered rows queued.
    /// `processedCount` is zero only when no row it could answer is left — the
    /// caller drains until then; a batch of clean rows is still progress.
    func drainStoredSoftHyphenRepairBatch(limit: Int, repairs: Int = 1, now: Date = Date()) throws -> StoredSoftHyphenRepairBatch {
        guard try holdsStoredSoftHyphenRepairQueue() else { return .empty }
        var rows: [(sourceID: String, holdsSoftHyphen: Bool)] = []
        try query(Self.storedSoftHyphenBatchSQL, [.integer(Int64(max(1, min(limit, 200))))]) { row in
            guard let sourceID = row.text(0) else { return }
            rows.append((sourceID, row.integer(1) == 1))
        }
        guard !rows.isEmpty else { return .empty }

        let clean = rows.filter { !$0.holdsSoftHyphen }.map(\.sourceID)
        if !clean.isEmpty {
            let placeholders = Array(repeating: "?", count: clean.count).joined(separator: ", ")
            try execute(
                "DELETE FROM source_text_soft_hyphen_repair_queue WHERE source_id IN (\(placeholders))",
                clean.map { .text($0) }
            )
        }
        var batch = StoredSoftHyphenRepairBatch(processedCount: clean.count, repairedSourceIDs: [])
        var answered = 0
        for row in rows where row.holdsSoftHyphen && answered < max(1, repairs) {
            switch try repairStoredSoftHyphens(sourceID: row.sourceID, now: now) {
            case .repaired:
                answered += 1
                batch.processedCount += 1
                batch.repairedSourceIDs.append(row.sourceID)
            case .unchanged:
                answered += 1
                batch.processedCount += 1
            case .busy:
                // A paid pass took the source since the batch was read; it waits.
                break
            }
        }
        return batch
    }

    enum StoredSoftHyphenRepairOutcome: Equatable {
        case repaired
        case unchanged
        case busy
    }

    /// Repairs one source in its own transaction. A failure rolls the source back
    /// and moves its row to the back of the queue, so one source the repair
    /// cannot write never holds the rest up, and is tried again by a later drain.
    func repairStoredSoftHyphens(sourceID: String, now: Date = Date()) throws -> StoredSoftHyphenRepairOutcome {
        try exec("BEGIN IMMEDIATE")
        do {
            let outcome = try repairStoredSoftHyphensInTransaction(sourceID: sourceID, now: now)
            try exec("COMMIT")
            return outcome
        } catch {
            try? exec("ROLLBACK")
            try? execute(
                "UPDATE source_text_soft_hyphen_repair_queue SET enqueued_at = ? WHERE source_id = ?",
                [.real(now.timeIntervalSinceReferenceDate), .text(sourceID)]
            )
            throw error
        }
    }

    /// The repair proper, read and written under one write lock.
    ///
    /// The canonical text C becomes C' without its soft hyphens. Everything this
    /// Mac derived from C is kept, re-stamped from C's hash to C''s, but only
    /// where it was bound to C — a derivative of some older text stays as stale as
    /// it was, and its owner (the clean-up, the integrity audit, Listen) remakes it
    /// as before. A text's own soft hyphens go with it:
    /// - a paper's or article's raw extraction is repaired, and its `raw_sha256`
    ///   re-stamped, only while that hash still attests it (`raw_sha256 = H(raw)`);
    ///   a raw whose hash does not is the integrity audit's, and is left alone;
    ///   `clean_sha256` follows C when it named C;
    /// - a podcast transcript's input the same way (`input_sha256`), and its
    ///   `clean_sha256` when it named C;
    /// - the Listen text, when it was prepared from C (`H(trim C)`): its text
    ///   repaired, its hash `H(trim C')`;
    /// - the review guide, the walkthrough (through `walkthroughText(_:matches:)`,
    ///   so a video's walk over its transcript alone follows too), the ideas and
    ///   the reading levels, when stamped with C's hash; an idea's statement, recall
    ///   note and anchor quotes lose their soft hyphens with it, and the idea is
    ///   republished;
    /// - the title, whatever the text.
    /// A changed C drops the source's full-text row, embeddings and index state and
    /// queues its satellites for publishing (`invalidateCanonicalContentIndexes`),
    /// and retires a pending review-guide preparation, as every text change does.
    /// A title alone rewrites the full-text row only; a derivative alone publishes
    /// the satellites again. The source is marked changed either way, which is a
    /// republish under generation 1 and nothing more under generation 2, whose
    /// outbox triggers record the title themselves.
    private func repairStoredSoftHyphensInTransaction(sourceID: String, now: Date) throws -> StoredSoftHyphenRepairOutcome {
        guard try scalarInteger("""
            SELECT EXISTS (SELECT 1 FROM canonical_content_cleanup_queue WHERE source_id = ?1)
                OR EXISTS (SELECT 1 FROM podcast_transcript_cleanup_queue WHERE source_id = ?1)
                OR EXISTS (SELECT 1 FROM source_listenable_content_queue WHERE source_id = ?1)
        """, [.text(sourceID)]) == 0 else { return .busy }

        let sha256 = PaperContentPreparationService.sha256
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // The canonical text.
        let content = try scalarText("SELECT content FROM source_content WHERE source_id = ?", [.text(sourceID)])
        let repairedContent = content.map(StoredSoftHyphens.repaired)
        let textChanged = content != nil && repairedContent != content
        if textChanged, let repairedContent {
            try execute("UPDATE source_content SET content = ? WHERE source_id = ?", [.text(repairedContent), .text(sourceID)])
        }
        // C's hashes, and what they become: nil when nothing stamped with them moves.
        let oldHash = content.map(sha256)
        let newHash = repairedContent.map(sha256)
        let oldListenHash = content.map { sha256(trimmed($0)) }
        let newListenHash = repairedContent.map { sha256(trimmed($0)) }
        func restamped(_ stamp: String?) -> String? {
            guard textChanged, let stamp, stamp == oldHash else { return stamp }
            return newHash
        }

        var derivativesChanged = false

        // A paper's or an article's extraction and clean-up proof.
        for table in ["paper_content_preparations", "article_content_preparations"] {
            var stored: (raw: String, rawSHA: String, cleanSHA: String?)?
            try query("SELECT raw_content, raw_sha256, clean_sha256 FROM \(table) WHERE source_id = ?", [.text(sourceID)]) { row in
                guard let raw = row.text(0), let rawSHA = row.text(1) else { return }
                stored = (raw, rawSHA, row.text(2))
            }
            guard let stored else { continue }
            var raw = stored.raw
            var rawSHA = stored.rawSHA
            if rawSHA == sha256(raw) {
                let repairedRaw = StoredSoftHyphens.repaired(raw)
                if repairedRaw != raw {
                    raw = repairedRaw
                    rawSHA = sha256(repairedRaw)
                }
            }
            let cleanSHA = restamped(stored.cleanSHA)
            guard raw != stored.raw || cleanSHA != stored.cleanSHA else { continue }
            try execute(
                "UPDATE \(table) SET raw_content = ?, raw_sha256 = ?, clean_sha256 = ? WHERE source_id = ?",
                [.text(raw), .text(rawSHA), .text(cleanSHA), .text(sourceID)]
            )
            derivativesChanged = true
        }

        // A podcast transcript's input and ad clean-up proof.
        var podcast: (input: String, inputSHA: String, cleanSHA: String)?
        try query(
            "SELECT input_content, input_sha256, clean_sha256 FROM podcast_transcript_preparations WHERE source_id = ?",
            [.text(sourceID)]
        ) { row in
            guard let input = row.text(0), let inputSHA = row.text(1), let cleanSHA = row.text(2) else { return }
            podcast = (input, inputSHA, cleanSHA)
        }
        if let podcast {
            var input = podcast.input
            var inputSHA = podcast.inputSHA
            if inputSHA == sha256(input) {
                let repairedInput = StoredSoftHyphens.repaired(input)
                if repairedInput != input {
                    input = repairedInput
                    inputSHA = sha256(repairedInput)
                }
            }
            let cleanSHA = restamped(podcast.cleanSHA) ?? podcast.cleanSHA
            if input != podcast.input || cleanSHA != podcast.cleanSHA {
                try execute(
                    "UPDATE podcast_transcript_preparations SET input_content = ?, input_sha256 = ?, clean_sha256 = ? WHERE source_id = ?",
                    [.text(input), .text(inputSHA), .text(cleanSHA), .text(sourceID)]
                )
                derivativesChanged = true
            }
        }

        // The Listen text, prepared from C's trimmed text.
        var listen: (text: String, sha: String)?
        try query("SELECT content, source_sha256 FROM source_listenable_content WHERE source_id = ?", [.text(sourceID)]) { row in
            guard let text = row.text(0), let sha = row.text(1) else { return }
            listen = (text, sha)
        }
        if let listen, let oldListenHash, let newListenHash, listen.sha == oldListenHash {
            let text = StoredSoftHyphens.repaired(listen.text)
            if text != listen.text || newListenHash != listen.sha {
                try execute(
                    "UPDATE source_listenable_content SET content = ?, source_sha256 = ? WHERE source_id = ?",
                    [.text(text), .text(newListenHash), .text(sourceID)]
                )
                derivativesChanged = true
            }
        }

        if textChanged, let content, let repairedContent, let oldHash, let newHash {
            // The review guide, written from C.
            var guide: (text: String, sha: String)?
            try query("SELECT guide, source_sha256 FROM source_review_guides WHERE source_id = ?", [.text(sourceID)]) { row in
                guard let text = row.text(0), let sha = row.text(1) else { return }
                guide = (text, sha)
            }
            if let guide, guide.sha == oldHash {
                try execute(
                    "UPDATE source_review_guides SET guide = ?, source_sha256 = ? WHERE source_id = ?",
                    [.text(StoredSoftHyphens.repaired(guide.text)), .text(newHash), .text(sourceID)]
                )
                derivativesChanged = true
            }

            // The walkthrough, written against C or, for a video, against its
            // transcript alone. The record's JSON carries the same stamp.
            var walk: (sha: String, json: String)?
            try query("SELECT source_sha256, walkthrough_json FROM source_walkthroughs WHERE source_id = ?", [.text(sourceID)]) { row in
                guard let sha = row.text(0), let json = row.text(1) else { return }
                walk = (sha, json)
            }
            if let walk, Self.walkthroughText(content, matches: walk.sha) {
                let walkedSHA = walk.sha == oldHash
                    ? newHash
                    : sha256(PaperWalkthroughSubject.walkedText(of: repairedContent))
                if walkedSHA != walk.sha {
                    try execute(
                        "UPDATE source_walkthroughs SET source_sha256 = ?, walkthrough_json = ? WHERE source_id = ?",
                        [.text(walkedSHA), .text(walk.json.replacingOccurrences(of: walk.sha, with: walkedSHA)), .text(sourceID)]
                    )
                    derivativesChanged = true
                }
            }

            // The ideas extracted from C, kept as they are with C''s hash: the
            // extraction compares that hash with the text's and would bill the
            // same ideas again.
            var ideas: [(id: String, statement: String, note: String, anchors: String)] = []
            try query(
                "SELECT id, statement, recall_note, anchors_json FROM source_ideas WHERE source_id = ? AND content_hash = ?",
                [.text(sourceID), .text(oldHash)]
            ) { row in
                guard let id = row.text(0), let statement = row.text(1) else { return }
                ideas.append((id, statement, row.text(2) ?? "", row.text(3) ?? "[]"))
            }
            for idea in ideas {
                try execute("""
                    UPDATE source_ideas
                    SET statement = ?, recall_note = ?, anchors_json = ?, content_hash = ?, updated_at = ?
                    WHERE id = ?
                """, [
                    .text(StoredSoftHyphens.repaired(idea.statement)),
                    .text(StoredSoftHyphens.repaired(idea.note)),
                    .text(Self.anchorsJSONWithoutSoftHyphens(idea.anchors)),
                    .text(newHash),
                    .real(now.timeIntervalSinceReferenceDate),
                    .text(idea.id),
                ])
            }

            // The reading levels, written from C. Local to this Mac.
            try execute(
                "UPDATE source_levels SET content_sha256 = ? WHERE source_id = ? AND content_sha256 = ?",
                [.text(newHash), .text(sourceID), .text(oldHash)]
            )
        }

        // The title, in whichever per-type table holds it.
        var titleChanged = false
        for table in SourceLocalTables.subtypeTables {
            guard let title = try scalarText("SELECT title FROM \(table) WHERE source_id = ?", [.text(sourceID)]) else { continue }
            let repairedTitle = StoredSoftHyphens.repaired(title)
            guard repairedTitle != title else { continue }
            try execute(
                "UPDATE \(table) SET title = ? WHERE source_id = ? AND title = ?",
                [.text(repairedTitle), .text(sourceID), .text(title)]
            )
            titleChanged = true
        }

        if textChanged {
            try invalidateCanonicalContentIndexes(sourceID: sourceID)
            try retireSourceReviewGuidePreparation(sourceID: sourceID)
        } else {
            if titleChanged {
                // The title is indexed: the full-text row is written again; the
                // embeddings stay.
                try execute("DELETE FROM source_fts_state WHERE source_id = ?", [.text(sourceID)])
            }
            if derivativesChanged {
                try queueSourceFilesRefresh(sourceID: sourceID)
            }
        }
        let changed = textChanged || titleChanged || derivativesChanged
        if changed {
            noteStoreChanged()
        }
        try execute("DELETE FROM source_text_soft_hyphen_repair_queue WHERE source_id = ?", [.text(sourceID)])
        return changed ? .repaired : .unchanged
    }

    /// An idea's anchors with their quotes repaired, in the shape the idea store
    /// writes; the stored JSON as it was when it does not read as anchors.
    static func anchorsJSONWithoutSoftHyphens(_ json: String) -> String {
        guard StoredSoftHyphens.holdsSoftHyphen(json),
              let anchors = try? JSONDecoder().decode([SourceIdeaAnchor].self, from: Data(json.utf8)) else { return json }
        let repaired = anchors.map { SourceIdeaAnchor(quote: StoredSoftHyphens.repaired($0.quote), highlightID: $0.highlightID) }
        guard repaired != anchors,
              let data = try? JSONEncoder().encode(repaired),
              let text = String(data: data, encoding: .utf8) else { return json }
        return text
    }
}
