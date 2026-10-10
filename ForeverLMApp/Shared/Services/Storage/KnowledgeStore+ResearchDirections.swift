import Foundation
import SQLite3

// MARK: - Directions (docs/directions-design.md)
//
// One row a Direction in `research_directions`, its evidence as JSON in the
// same row; each travels as one `ResearchDirection` CloudKit record
// (`CloudKitResearchDirectionPayload`). A Direction is proposed by a search
// and answered by the learner, and both are writes here: every one is queued
// for sync at once and republishes the whole record.
//
// Identity is the store's, never a model's: the id is minted here, the home
// is checked against the table its kind means, and a proposal that repeats a
// Direction the home already has (by `ResearchDirection.duplicateKey`) is
// skipped rather than written twice.

/// What a search hands the store for one proposal, before it has an id.
struct ResearchDirectionDraft: Equatable, Sendable {
    var title: String
    var rationale: String
    var angle: DirectionAngle
    var evidence: [DirectionEvidence]
    var objection: String?
    var nextStep: String?
}

/// A change to one Direction. nil leaves a field alone; `evidenceToAdd` is
/// appended after the evidence it already has.
struct ResearchDirectionChange: Equatable, Sendable {
    var title: String?
    var rationale: String?
    var objection: String?
    var nextStep: String?
    var evidenceToAdd: [DirectionEvidence] = []
    var status: DirectionStatus?
    /// The learner's reason. Written with a status change; on its own it
    /// rewrites the reason for the answer already given.
    var verdictReason: String?

    var isEmpty: Bool {
        title == nil && rationale == nil && objection == nil && nextStep == nil
            && evidenceToAdd.isEmpty && status == nil && verdictReason == nil
    }
}

extension KnowledgeStore {

    // MARK: Reads

    /// Directions, in list order (pursued, proposed, set aside; newest first
    /// within each). `homeID` scopes to one Goal, Notebook or Idea.
    func loadResearchDirections(homeID: String? = nil, statuses: Set<DirectionStatus>? = nil) throws -> [ResearchDirection] {
        var rows: [ResearchDirection] = []
        if let homeID {
            try queryBind("\(Self.researchDirectionColumns) WHERE home_id = ?", bind: { stmt in
                self.bind(stmt, 1, homeID)
            }) { stmt in
                if let direction = self.researchDirection(from: stmt) { rows.append(direction) }
            }
        } else {
            try query(Self.researchDirectionColumns) { stmt in
                if let direction = self.researchDirection(from: stmt) { rows.append(direction) }
            }
        }
        if let statuses {
            rows = rows.filter { statuses.contains($0.status) }
        }
        return rows.sorted(by: ResearchDirection.listOrder)
    }

    func loadResearchDirection(_ directionID: String) throws -> ResearchDirection? {
        var direction: ResearchDirection?
        try queryBind("\(Self.researchDirectionColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, directionID)
        }) { stmt in
            direction = self.researchDirection(from: stmt)
        }
        return direction
    }

    func hasResearchDirection(_ directionID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM research_directions WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, directionID)
        }) { _ in
            found = true
        }
        return found
    }

    func loadAllResearchDirectionIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM research_directions") { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// What an id names as a Direction's home: a Goal (a companion record
    /// with a deadline), a Notebook (one without), or an Idea. nil when the
    /// library holds none of them under that id.
    func researchDirectionHomeKind(_ homeID: String) throws -> DirectionHomeKind? {
        if let record = try loadLearningGoal(homeID) {
            if record.isGoal { return .goal }
            if record.isNotebook { return .notebook }
            return nil
        }
        if try hasIdea(homeID) { return .idea }
        return nil
    }

    /// The library source a piece of evidence names, by its DOI first and
    /// its address second. Deterministic lookups only.
    func librarySourceID(for evidence: DirectionEvidence) throws -> String? {
        if let doi = DirectionEvidence.normalizedDOI(evidence.doi), let match = try sourceIDByDOI(doi) {
            return match
        }
        if let url = cleanIdentityValue(evidence.url) {
            if let match = try sourceIDByNormalizedURL(URLNormalizer.normalize(url)) { return match }
            if let match = try sourceIDByURL(url) { return match }
            // A doi.org address is the DOI said another way.
            if let doi = DirectionEvidence.normalizedDOI(url), let match = try sourceIDByDOI(doi) { return match }
        }
        return nil
    }

    // MARK: Writes

    /// Save a search's proposals for one home. Each draft needs a sentence,
    /// a reason it is worth a look, and at least one piece of evidence with
    /// a DOI or an address; a draft missing any of them refuses the whole
    /// call before anything is written, so a search never half-saves. A
    /// draft that repeats a Direction the home already has — proposed,
    /// pursued or set aside — is skipped and named in `duplicates`.
    @discardableResult
    func proposeResearchDirections(
        homeID rawHomeID: String,
        drafts: [ResearchDirectionDraft],
        chatSessionID rawChatSessionID: String? = nil
    ) throws -> (saved: [ResearchDirection], duplicates: [String]) {
        let homeID = rawHomeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let homeKind = try researchDirectionHomeKind(homeID) else {
            throw KnowledgeStoreError.invalidData("No Goal, Notebook or Idea with id \(homeID) is in the library.")
        }
        guard !drafts.isEmpty else {
            throw KnowledgeStoreError.invalidData("Pass at least one direction to save.")
        }
        guard drafts.count <= ResearchDirection.proposalBatchLimit else {
            throw KnowledgeStoreError.invalidData("Save at most \(ResearchDirection.proposalBatchLimit) directions at a time; a search that found more has not chosen yet.")
        }
        let chatSessionID = rawChatSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        var prepared: [ResearchDirection] = []
        for (offset, draft) in drafts.enumerated() {
            let label = "Direction \(offset + 1)"
            let title = ResearchDirection.normalizedTitle(draft.title)
            guard !title.isEmpty else {
                throw KnowledgeStoreError.invalidData("\(label) has no sentence: say the approach and what it is aimed at.")
            }
            guard let rationale = ResearchDirection.normalizedText(draft.rationale) else {
                throw KnowledgeStoreError.invalidData("\(label) (\(title)) says nothing about why it is worth a look now.")
            }
            let evidence = try Self.normalizedEvidence(draft.evidence, label: "\(label) (\(title))")
            guard !evidence.isEmpty else {
                throw KnowledgeStoreError.invalidData("\(label) (\(title)) cites nothing. Every direction needs at least one paper or page you opened, with its DOI or address.")
            }
            prepared.append(ResearchDirection(
                homeKind: homeKind,
                homeID: homeID,
                title: title,
                rationale: rationale,
                angle: draft.angle,
                evidence: evidence,
                objection: ResearchDirection.normalizedText(draft.objection),
                nextStep: ResearchDirection.normalizedText(draft.nextStep),
                status: .proposed,
                chatSessionID: chatSessionID?.isEmpty == false ? chatSessionID : nil,
                // A strictly later time per proposal keeps the search's own
                // order when the list sorts newest first.
                createdAt: now.addingTimeInterval(-Double(offset) * 0.001),
                updatedAt: now
            ))
        }

        var seen = Set(try loadResearchDirections(homeID: homeID).map { ResearchDirection.duplicateKey($0.title) })
        var saved: [ResearchDirection] = []
        var duplicates: [String] = []
        for direction in prepared {
            if seen.insert(ResearchDirection.duplicateKey(direction.title)).inserted {
                saved.append(direction)
            } else {
                duplicates.append(direction.title)
            }
        }
        guard !saved.isEmpty else { return ([], duplicates) }

        try exec("BEGIN IMMEDIATE")
        do {
            for direction in saved {
                try writeResearchDirectionRow(direction)
                try markRecordChanged(entity: .researchDirection, logicalKey: direction.id, at: now)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return (saved, duplicates)
    }

    /// Change one Direction: the learner's answer (pursue, set aside, back to
    /// proposed) with their reason, a rewording, or evidence a deeper look
    /// found. Answering records when; going back to proposed clears the
    /// answer and its reason.
    @discardableResult
    func updateResearchDirection(_ directionID: String, change: ResearchDirectionChange) throws -> ResearchDirection {
        guard var direction = try loadResearchDirection(directionID) else {
            throw KnowledgeStoreError.invalidData("Direction not found: \(directionID)")
        }
        guard !change.isEmpty else { return direction }
        if let rawTitle = change.title {
            let title = ResearchDirection.normalizedTitle(rawTitle)
            guard !title.isEmpty else {
                throw KnowledgeStoreError.invalidData("A direction cannot be left without its sentence.")
            }
            direction.title = title
        }
        if let rawRationale = change.rationale {
            guard let rationale = ResearchDirection.normalizedText(rawRationale) else {
                throw KnowledgeStoreError.invalidData("A direction needs its reason to be worth a look.")
            }
            direction.rationale = rationale
        }
        if let objection = change.objection {
            direction.objection = ResearchDirection.normalizedText(objection)
        }
        if let nextStep = change.nextStep {
            direction.nextStep = ResearchDirection.normalizedText(nextStep)
        }
        if !change.evidenceToAdd.isEmpty {
            let added = try Self.normalizedEvidence(change.evidenceToAdd, label: "The new evidence")
            direction.evidence = Self.dedupedEvidence(direction.evidence + added)
            guard direction.evidence.count <= ResearchDirection.evidenceLimit else {
                throw KnowledgeStoreError.invalidData("A direction keeps at most \(ResearchDirection.evidenceLimit) pieces of evidence; it has \(direction.evidence.count) with these.")
            }
        }
        let now = Date()
        if let status = change.status {
            if status != direction.status {
                direction.status = status
                direction.decidedAt = status == .proposed ? nil : now
                direction.verdictReason = status == .proposed
                    ? nil
                    : ResearchDirection.normalizedText(change.verdictReason, limit: ResearchDirection.reasonLimit)
            } else if let reason = change.verdictReason, status != .proposed {
                direction.verdictReason = ResearchDirection.normalizedText(reason, limit: ResearchDirection.reasonLimit)
            }
        } else if let reason = change.verdictReason {
            guard direction.status != .proposed else {
                throw KnowledgeStoreError.invalidData("A reason goes with an answer: pass status pursued or set_aside with it.")
            }
            direction.verdictReason = ResearchDirection.normalizedText(reason, limit: ResearchDirection.reasonLimit)
        }
        direction.updatedAt = now
        try exec("BEGIN IMMEDIATE")
        do {
            try writeResearchDirectionRow(direction)
            try markRecordChanged(entity: .researchDirection, logicalKey: direction.id, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return direction
    }

    /// Forget one Direction. Nothing it cited is touched.
    func deleteResearchDirection(_ directionID: String) throws {
        guard try hasResearchDirection(directionID) else {
            throw KnowledgeStoreError.invalidData("Direction not found: \(directionID)")
        }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM research_directions WHERE id = ?") { stmt in self.bind(stmt, 1, directionID) }
            try markRecordDeleted(entity: .researchDirection, logicalKey: directionID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A home's Directions go with it: deleting a Goal or an Idea deletes
    /// what was proposed toward it, tombstones included. Runs inside the
    /// caller's transaction; it opens none of its own.
    func deleteResearchDirectionRowsInTransaction(homeID: String, at date: Date) throws {
        var ids: [String] = []
        try queryBind("SELECT id FROM research_directions WHERE home_id = ?", bind: { stmt in
            self.bind(stmt, 1, homeID)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        guard !ids.isEmpty else { return }
        try execBind("DELETE FROM research_directions WHERE home_id = ?") { stmt in self.bind(stmt, 1, homeID) }
        for id in ids {
            try markRecordDeleted(entity: .researchDirection, logicalKey: id, at: date)
        }
    }

    // MARK: CloudKit

    func loadResearchDirectionForSync(_ directionID: String) throws -> CloudKitResearchDirectionPayload? {
        guard let direction = try loadResearchDirection(directionID) else { return nil }
        return CloudKitResearchDirectionPayload(direction: direction)
    }

    /// Applies an inbound record. A Direction was last written whole on one
    /// device — proposed there, or answered there — so the newer record wins
    /// whole; `created_at` keeps the earlier of the two. The home is not
    /// checked: CloudKit may deliver a Direction before the Goal or Idea it
    /// is toward, and a Direction whose home never arrives is simply shown
    /// nowhere.
    func saveResearchDirectionRecord(_ payload: CloudKitResearchDirectionPayload) throws {
        var incoming = payload.direction
        let title = ResearchDirection.normalizedTitle(incoming.title)
        guard !title.isEmpty else {
            throw KnowledgeStoreError.invalidData("Inbound direction \(incoming.id) has no sentence.")
        }
        incoming.title = title
        if let existing = try loadResearchDirection(incoming.id) {
            guard incoming.updatedAt >= existing.updatedAt else { return }
            incoming = ResearchDirection(
                id: incoming.id,
                homeKind: incoming.homeKind,
                homeID: incoming.homeID,
                title: incoming.title,
                rationale: incoming.rationale,
                angle: incoming.angle,
                evidence: incoming.evidence,
                objection: incoming.objection,
                nextStep: incoming.nextStep,
                status: incoming.status,
                verdictReason: incoming.verdictReason,
                chatSessionID: incoming.chatSessionID,
                createdAt: min(existing.createdAt, incoming.createdAt),
                updatedAt: incoming.updatedAt,
                decidedAt: incoming.decidedAt
            )
        }
        try writeResearchDirectionRow(incoming)
    }

    func deleteResearchDirectionRecord(_ directionID: String) throws {
        try execBind("DELETE FROM research_directions WHERE id = ?") { stmt in self.bind(stmt, 1, directionID) }
    }

    func researchDirectionSyncBackfillDate(_ directionID: String) throws -> Date? {
        var date: Date?
        try queryBind("SELECT updated_at FROM research_directions WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, directionID)
        }) { stmt in
            date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return date
    }

    // MARK: Row plumbing

    private static let researchDirectionColumns = """
        SELECT id, home_kind, home_id, title, rationale, angle, evidence_json,
               objection, next_step, status, verdict_reason, chat_session_id,
               created_at, updated_at, decided_at
        FROM research_directions
    """

    private func researchDirection(from stmt: OpaquePointer?) -> ResearchDirection? {
        guard let id = string(stmt, 0),
              let homeKind = string(stmt, 1).flatMap(DirectionHomeKind.init(rawValue:)),
              let homeID = string(stmt, 2),
              let title = string(stmt, 3) else { return nil }
        let evidence: [DirectionEvidence] = string(stmt, 6)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([DirectionEvidence].self, from: $0) } ?? []
        let decided = sqlite3_column_type(stmt, 14) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 14))
        return ResearchDirection(
            id: id,
            homeKind: homeKind,
            homeID: homeID,
            title: title,
            rationale: string(stmt, 4) ?? "",
            angle: DirectionAngle(rawValue: string(stmt, 5) ?? "") ?? .other,
            evidence: evidence,
            objection: string(stmt, 7),
            nextStep: string(stmt, 8),
            status: DirectionStatus(rawValue: string(stmt, 9) ?? "") ?? .proposed,
            verdictReason: string(stmt, 10),
            chatSessionID: string(stmt, 11),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 12)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 13)),
            decidedAt: decided
        )
    }

    private func writeResearchDirectionRow(_ direction: ResearchDirection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let evidenceJSON = String(data: try encoder.encode(direction.evidence), encoding: .utf8) ?? "[]"
        try execBind("""
            INSERT INTO research_directions (
                id, home_kind, home_id, title, rationale, angle, evidence_json,
                objection, next_step, status, verdict_reason, chat_session_id,
                created_at, updated_at, decided_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                rationale = excluded.rationale,
                angle = excluded.angle,
                evidence_json = excluded.evidence_json,
                objection = excluded.objection,
                next_step = excluded.next_step,
                status = excluded.status,
                verdict_reason = excluded.verdict_reason,
                chat_session_id = excluded.chat_session_id,
                created_at = MIN(research_directions.created_at, excluded.created_at),
                updated_at = excluded.updated_at,
                decided_at = excluded.decided_at
        """) { stmt in
            self.bind(stmt, 1, direction.id)
            self.bind(stmt, 2, direction.homeKind.rawValue)
            self.bind(stmt, 3, direction.homeID)
            self.bind(stmt, 4, direction.title)
            self.bind(stmt, 5, direction.rationale)
            self.bind(stmt, 6, direction.angle.rawValue)
            self.bind(stmt, 7, evidenceJSON)
            self.bind(stmt, 8, direction.objection)
            self.bind(stmt, 9, direction.nextStep)
            self.bind(stmt, 10, direction.status.rawValue)
            self.bind(stmt, 11, direction.verdictReason)
            self.bind(stmt, 12, direction.chatSessionID)
            self.bind(stmt, 13, direction.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 14, direction.updatedAt.timeIntervalSinceReferenceDate)
            if let decidedAt = direction.decidedAt {
                self.bind(stmt, 15, decidedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 15)
            }
        }
    }

    /// Evidence as stored: citation and finding trimmed, a DOI in its bare
    /// form, an address only when it is one, and at least one of the two —
    /// the thing that says which paper or page it is. Refuses, naming the
    /// item, when an entry has neither or says nothing.
    static func normalizedEvidence(_ raw: [DirectionEvidence], label: String) throws -> [DirectionEvidence] {
        var cleaned: [DirectionEvidence] = []
        for (offset, item) in raw.enumerated() {
            let itemLabel = "\(label), evidence \(offset + 1)"
            let doi = DirectionEvidence.normalizedDOI(item.doi)
            let url = ResearchDirection.normalizedText(item.url, limit: 2_000).flatMap { value -> String? in
                guard let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", parsed.host != nil else { return nil }
                return value
            }
            guard doi != nil || url != nil else {
                throw KnowledgeStoreError.invalidData("\(itemLabel) has neither a DOI nor a web address, so nobody can open it.")
            }
            guard let finding = ResearchDirection.normalizedText(item.finding, limit: 1_000) else {
                throw KnowledgeStoreError.invalidData("\(itemLabel) does not say what it shows for this direction.")
            }
            let citation = ResearchDirection.normalizedText(item.citation, limit: 300)
                ?? ResearchDirection.normalizedText(item.title, limit: 300)
                ?? doi ?? url ?? ""
            cleaned.append(DirectionEvidence(
                citation: citation,
                title: ResearchDirection.normalizedText(item.title, limit: 500),
                url: url,
                doi: doi,
                finding: finding
            ))
        }
        let deduped = dedupedEvidence(cleaned)
        guard deduped.count <= ResearchDirection.evidenceLimit else {
            throw KnowledgeStoreError.invalidData("\(label) cites \(deduped.count) items; keep the \(ResearchDirection.evidenceLimit) that matter most.")
        }
        return deduped
    }

    /// One entry per paper or page: the same DOI, or failing a DOI the same
    /// address, is kept once, first occurrence first.
    static func dedupedEvidence(_ evidence: [DirectionEvidence]) -> [DirectionEvidence] {
        var seen = Set<String>()
        return evidence.filter { item in
            let key = item.doi.map { "doi:\($0)" } ?? item.url.map { "url:\(URLNormalizer.normalize($0))" } ?? "cite:\(item.citation)"
            return seen.insert(key).inserted
        }
    }
}
