import Foundation
import SQLite3

// MARK: - Ideas (the learner's own; docs/ideas-design.md)
//
// One row an Idea in `ideas`, one row a link in `idea_links`; the two travel
// as one `Idea` CloudKit record (`CloudKitIdeaPayload`). Every write here is
// the learner's hand — a thought jotted down, a link made — so each is
// queued for sync at once and the whole record is republished, links
// included, the way a day plan republishes with its blocks.
//
// `SourceIdea` (KnowledgeStore+Ideas.swift) is a different thing: the memory
// unit extracted from a source's text. Nothing here reads that table.

extension KnowledgeStore {

    // MARK: Reads

    func loadIdeas(includeArchived: Bool = true) throws -> [IdeaRecord] {
        var rows: [IdeaRecord] = []
        let sql = includeArchived
            ? "\(Self.ideaColumns) ORDER BY created_at DESC, id"
            : "\(Self.ideaColumns) WHERE status = 'open' ORDER BY created_at DESC, id"
        try query(sql) { stmt in
            if let idea = self.idea(from: stmt) { rows.append(idea) }
        }
        guard !rows.isEmpty else { return [] }
        let links = try loadIdeaLinks(ideaIDs: rows.map(\.id))
        return rows.map { idea in
            var idea = idea
            idea.links = links[idea.id] ?? []
            return idea
        }
    }

    func loadIdea(_ ideaID: String) throws -> IdeaRecord? {
        var idea: IdeaRecord?
        try queryBind("\(Self.ideaColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, ideaID)
        }) { stmt in
            idea = self.idea(from: stmt)
        }
        guard var found = idea else { return nil }
        found.links = try loadIdeaLinks(ideaIDs: [found.id])[found.id] ?? []
        return found
    }

    func hasIdea(_ ideaID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM ideas WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, ideaID)
        }) { _ in
            found = true
        }
        return found
    }

    /// The Ideas linked to one record, newest first: what a source's or a
    /// Goal's surface would ask to show the thought behind it.
    func loadIdeas(linkedTo kind: IdeaLinkKind, targetID: String) throws -> [IdeaRecord] {
        var ids: [String] = []
        try queryBind("""
            SELECT i.id FROM ideas i
            JOIN idea_links l ON l.idea_id = i.id
            WHERE l.kind = ? AND l.target_id = ?
            ORDER BY i.created_at DESC, i.id
        """, bind: { stmt in
            self.bind(stmt, 1, kind.rawValue)
            self.bind(stmt, 2, targetID)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return try ids.compactMap { try loadIdea($0) }
    }

    // MARK: Writes

    /// Jot an Idea down. The title is the one line the learner typed, trimmed
    /// and folded onto one line; an empty one is refused, because an Idea with
    /// no words is nothing to come back to. Links given here are made in the
    /// same transaction; every target must exist (`validateIdeaLinkTarget`).
    @discardableResult
    func createIdea(title rawTitle: String, notes rawNotes: String? = nil, links: [IdeaLink] = []) throws -> IdeaRecord {
        let title = IdeaRecord.normalizedTitle(rawTitle)
        guard !title.isEmpty else {
            throw KnowledgeStoreError.invalidData("An idea needs at least a few words.")
        }
        let now = Date()
        var idea = IdeaRecord(title: title, notes: IdeaRecord.normalizedNotes(rawNotes), createdAt: now, updatedAt: now)
        let uniqueLinks = Self.dedupedIdeaLinks(links.map { IdeaLink(kind: $0.kind, targetID: $0.targetID, addedAt: now) })
        for link in uniqueLinks {
            try validateIdeaLinkTarget(link)
        }
        idea.links = uniqueLinks
        try exec("BEGIN IMMEDIATE")
        do {
            try writeIdeaRow(idea)
            for link in idea.links {
                try writeIdeaLinkRow(ideaID: idea.id, link: link)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return idea
    }

    /// Reword an Idea or write its note. nil leaves a field as it is; a blank
    /// note clears it; a blank title is refused.
    @discardableResult
    func updateIdea(_ ideaID: String, title rawTitle: String? = nil, notes rawNotes: String? = nil) throws -> IdeaRecord {
        guard var idea = try loadIdea(ideaID) else {
            throw KnowledgeStoreError.invalidData("Idea not found: \(ideaID)")
        }
        if let rawTitle {
            let title = IdeaRecord.normalizedTitle(rawTitle)
            guard !title.isEmpty else {
                throw KnowledgeStoreError.invalidData("An idea needs at least a few words.")
            }
            idea.title = title
        }
        if let rawNotes {
            idea.notes = IdeaRecord.normalizedNotes(rawNotes)
        }
        idea.updatedAt = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try writeIdeaRow(idea)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return idea
    }

    /// Put an Idea away, or bring it back. Archive keeps everything — the
    /// words, the note, the links — and only moves the row to the tab's quiet
    /// line; Delete is the way to be rid of one.
    @discardableResult
    func setIdeaStatus(_ ideaID: String, status: IdeaStatus) throws -> IdeaRecord {
        guard var idea = try loadIdea(ideaID) else {
            throw KnowledgeStoreError.invalidData("Idea not found: \(ideaID)")
        }
        guard idea.status != status else { return idea }
        idea.status = status
        idea.updatedAt = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try writeIdeaRow(idea)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return idea
    }

    /// Link research or an exploration to an Idea: sources, chats, Docs and
    /// Sites, the Goal it became, the Notebook it draws on. A target already
    /// linked is skipped and counted; a target no record has is refused
    /// before anything is written. Returns the Idea as it now reads and how
    /// many links were new.
    @discardableResult
    func linkIdea(_ ideaID: String, kind: IdeaLinkKind, targetIDs rawTargetIDs: [String]) throws -> (idea: IdeaRecord, added: Int) {
        guard var idea = try loadIdea(ideaID) else {
            throw KnowledgeStoreError.invalidData("Idea not found: \(ideaID)")
        }
        let targetIDs = Self.uniqueTrimmed(rawTargetIDs)
        guard !targetIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("Name at least one \(kind.noun) to link.")
        }
        let already = Set(idea.linkedIDs(kind))
        let now = Date()
        let fresh = targetIDs.filter { !already.contains($0) }.map { IdeaLink(kind: kind, targetID: $0, addedAt: now) }
        for link in fresh {
            try validateIdeaLinkTarget(link)
        }
        guard !fresh.isEmpty else { return (idea, 0) }
        idea.links.append(contentsOf: fresh)
        idea.updatedAt = now
        try exec("BEGIN IMMEDIATE")
        do {
            try writeIdeaRow(idea)
            for link in fresh {
                try writeIdeaLinkRow(ideaID: idea.id, link: link)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return (idea, fresh.count)
    }

    /// Take links off an Idea. A target that was not linked is skipped; the
    /// records themselves are untouched.
    @discardableResult
    func unlinkIdea(_ ideaID: String, kind: IdeaLinkKind, targetIDs rawTargetIDs: [String]) throws -> (idea: IdeaRecord, removed: Int) {
        guard var idea = try loadIdea(ideaID) else {
            throw KnowledgeStoreError.invalidData("Idea not found: \(ideaID)")
        }
        let targetIDs = Set(Self.uniqueTrimmed(rawTargetIDs))
        guard !targetIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("Name at least one \(kind.noun) to unlink.")
        }
        let before = idea.links.count
        idea.links.removeAll { $0.kind == kind && targetIDs.contains($0.targetID) }
        let removed = before - idea.links.count
        guard removed > 0 else { return (idea, 0) }
        let now = Date()
        idea.updatedAt = now
        try exec("BEGIN IMMEDIATE")
        do {
            try writeIdeaRow(idea)
            let placeholders = targetIDs.map { _ in "?" }.joined(separator: ",")
            try execBind("DELETE FROM idea_links WHERE idea_id = ? AND kind = ? AND target_id IN (\(placeholders))") { stmt in
                self.bind(stmt, 1, idea.id)
                self.bind(stmt, 2, kind.rawValue)
                for (offset, targetID) in targetIDs.sorted().enumerated() {
                    self.bind(stmt, 3 + offset, targetID)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return (idea, removed)
    }

    /// Forget an Idea: the row and its links. Nothing it was linked to is
    /// touched — the sources, chats, Docs, Goals and Notebooks stay as they were.
    func deleteIdea(_ ideaID: String) throws {
        guard try hasIdea(ideaID) else {
            throw KnowledgeStoreError.invalidData("Idea not found: \(ideaID)")
        }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM idea_links WHERE idea_id = ?") { stmt in self.bind(stmt, 1, ideaID) }
            try execBind("DELETE FROM ideas WHERE id = ?") { stmt in self.bind(stmt, 1, ideaID) }
            // What was proposed toward the Idea goes with it
            // (docs/directions-design.md).
            try deleteResearchDirectionRowsInTransaction(homeID: ideaID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A link may only name a record this library holds; the id is checked
    /// against the table its kind means, so an Idea never carries a chip that
    /// opens nothing.
    func validateIdeaLinkTarget(_ link: IdeaLink) throws {
        let id = link.targetID
        let exists: Bool
        switch link.kind {
        case .source:
            exists = try sourceExists(id)
        case .artifact:
            exists = try loadArtifact(id) != nil
        case .chat:
            exists = try hasReviewSession(id)
        case .goal:
            exists = try loadLearningGoal(id)?.isGoal == true
        case .notebook:
            exists = try loadLearningGoal(id)?.isNotebook == true
        }
        guard exists else {
            throw KnowledgeStoreError.invalidData("No \(link.kind.noun) with id \(id) is in the library.")
        }
    }

    private func hasReviewSession(_ sessionID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM review_sessions WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, sessionID)
        }) { _ in
            found = true
        }
        return found
    }

    // MARK: CloudKit

    // MARK: Row plumbing

    private static let ideaColumns = """
        SELECT id, title, notes, status, created_at, updated_at
        FROM ideas
    """

    private func idea(from stmt: OpaquePointer?) -> IdeaRecord? {
        guard let id = string(stmt, 0), let title = string(stmt, 1) else { return nil }
        return IdeaRecord(
            id: id,
            title: title,
            notes: string(stmt, 2),
            status: IdeaStatus(rawValue: string(stmt, 3) ?? "") ?? .open,
            links: [],
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
        )
    }

    private func loadIdeaLinks(ideaIDs: [String]) throws -> [String: [IdeaLink]] {
        guard !ideaIDs.isEmpty else { return [:] }
        var links: [String: [IdeaLink]] = [:]
        let placeholders = ideaIDs.map { _ in "?" }.joined(separator: ",")
        try queryBind("""
            SELECT idea_id, kind, target_id, added_at FROM idea_links
            WHERE idea_id IN (\(placeholders))
            ORDER BY added_at, rowid
        """, bind: { stmt in
            for (offset, id) in ideaIDs.enumerated() {
                self.bind(stmt, 1 + offset, id)
            }
        }) { stmt in
            guard let ideaID = self.string(stmt, 0),
                  let kind = self.string(stmt, 1).flatMap(IdeaLinkKind.init(rawValue:)),
                  let targetID = self.string(stmt, 2) else { return }
            links[ideaID, default: []].append(IdeaLink(
                kind: kind,
                targetID: targetID,
                addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            ))
        }
        return links
    }

    private func writeIdeaRow(_ idea: IdeaRecord) throws {
        try execBind("""
            INSERT INTO ideas (id, title, notes, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                notes = excluded.notes,
                status = excluded.status,
                created_at = MIN(ideas.created_at, excluded.created_at),
                updated_at = excluded.updated_at
        """) { stmt in
            self.bind(stmt, 1, idea.id)
            self.bind(stmt, 2, idea.title)
            self.bind(stmt, 3, idea.notes)
            self.bind(stmt, 4, idea.status.rawValue)
            self.bind(stmt, 5, idea.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 6, idea.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    private func writeIdeaLinkRow(ideaID: String, link: IdeaLink) throws {
        try execBind("""
            INSERT INTO idea_links (idea_id, kind, target_id, added_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(idea_id, kind, target_id) DO UPDATE SET
                added_at = MIN(idea_links.added_at, excluded.added_at)
        """) { stmt in
            self.bind(stmt, 1, ideaID)
            self.bind(stmt, 2, link.kind.rawValue)
            self.bind(stmt, 3, link.targetID)
            self.bind(stmt, 4, link.addedAt.timeIntervalSinceReferenceDate)
        }
    }

    private static func uniqueTrimmed(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// One link per (kind, target), the first occurrence's date kept.
    static func dedupedIdeaLinks(_ links: [IdeaLink]) -> [IdeaLink] {
        var seen = Set<String>()
        return links.filter { seen.insert("\($0.kind.rawValue)\u{1F}\($0.targetID)").inserted }
    }
}
