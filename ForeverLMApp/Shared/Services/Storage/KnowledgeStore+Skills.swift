import Foundation
import SQLite3

// MARK: - Skills (the learner's own chat skills; docs/chat-design.md, "Skills")
//
// One row a skill in `skills`, travelling as one `Skill` CloudKit record.
// Every write here is the learner's hand, so each
// is queued for sync at once. The name is not unique in the table: it is the
// learner's handle, and two Macs that each wrote a skill of the same name
// must both arrive rather than fail the inbound apply. The local writes below
// refuse a name another skill already holds, so a clash only ever comes from
// sync, and `[SkillRecord].skill(named:)` resolves it to the newer edit.

extension KnowledgeStore {

    // MARK: Reads

    /// Every skill, by name.
    func loadSkills() throws -> [SkillRecord] {
        var rows: [SkillRecord] = []
        try query("\(Self.skillColumns) ORDER BY name, updated_at DESC, id") { stmt in
            if let skill = self.skill(from: stmt) { rows.append(skill) }
        }
        return rows
    }

    func loadSkill(_ skillID: String) throws -> SkillRecord? {
        var skill: SkillRecord?
        try queryBind("\(Self.skillColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, skillID)
        }) { stmt in
            skill = self.skill(from: stmt)
        }
        return skill
    }

    /// The skill a name calls: the most recently edited one with that name.
    func loadSkill(named rawName: String) throws -> SkillRecord? {
        let name = SkillRecord.normalizedName(rawName)
        guard !name.isEmpty else { return nil }
        var skill: SkillRecord?
        try queryBind("\(Self.skillColumns) WHERE name = ? ORDER BY updated_at DESC, id LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, name)
        }) { stmt in
            skill = self.skill(from: stmt)
        }
        return skill
    }

    func hasSkill(_ skillID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM skills WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, skillID)
        }) { _ in
            found = true
        }
        return found
    }

    // MARK: Writes

    /// Write a new skill. The name is normalized to a `/` command
    /// (`SkillRecord.normalizedName`) and must not already name another skill.
    @discardableResult
    func createSkill(name rawName: String, description rawDescription: String, instructions rawInstructions: String) throws -> SkillRecord {
        if let problem = SkillRecord.validationProblem(name: rawName, description: rawDescription, instructions: rawInstructions) {
            throw KnowledgeStoreError.invalidData(problem)
        }
        let name = SkillRecord.normalizedName(rawName)
        try requireSkillNameFree(name, except: nil)
        let now = Date()
        let skill = SkillRecord(
            name: name,
            description: SkillRecord.normalizedDescription(rawDescription),
            instructions: SkillRecord.normalizedInstructions(rawInstructions),
            createdAt: now,
            updatedAt: now
        )
        try exec("BEGIN IMMEDIATE")
        do {
            try writeSkillRow(skill)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return skill
    }

    /// Rename or rewrite a skill. nil leaves a field as it is; a field given
    /// is held to the same rules as a new skill's.
    @discardableResult
    func updateSkill(
        _ skillID: String,
        name rawName: String? = nil,
        description rawDescription: String? = nil,
        instructions rawInstructions: String? = nil
    ) throws -> SkillRecord {
        guard var skill = try loadSkill(skillID) else {
            throw KnowledgeStoreError.invalidData("Skill not found: \(skillID)")
        }
        let name = rawName ?? skill.name
        let description = rawDescription ?? skill.description
        let instructions = rawInstructions ?? skill.instructions
        if let problem = SkillRecord.validationProblem(name: name, description: description, instructions: instructions) {
            throw KnowledgeStoreError.invalidData(problem)
        }
        let normalizedName = SkillRecord.normalizedName(name)
        if normalizedName != skill.name {
            try requireSkillNameFree(normalizedName, except: skill.id)
        }
        let updated = SkillRecord(
            id: skill.id,
            name: normalizedName,
            description: SkillRecord.normalizedDescription(description),
            instructions: SkillRecord.normalizedInstructions(instructions),
            createdAt: skill.createdAt,
            updatedAt: skill.updatedAt
        )
        guard updated.name != skill.name
                || updated.description != skill.description
                || updated.instructions != skill.instructions else {
            return skill
        }
        let now = Date()
        skill = updated
        skill.updatedAt = now
        try exec("BEGIN IMMEDIATE")
        do {
            try writeSkillRow(skill)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return skill
    }

    func deleteSkill(_ skillID: String) throws {
        guard try hasSkill(skillID) else {
            throw KnowledgeStoreError.invalidData("Skill not found: \(skillID)")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM skills WHERE id = ?") { stmt in self.bind(stmt, 1, skillID) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func requireSkillNameFree(_ name: String, except skillID: String?) throws {
        var holder: String?
        try queryBind("SELECT id FROM skills WHERE name = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, name)
        }) { stmt in
            holder = self.string(stmt, 0)
        }
        if let holder, holder != skillID {
            throw KnowledgeStoreError.invalidData("You already have a skill called /\(name). Pick another name, or edit that one.")
        }
    }

    // MARK: CloudKit

    // MARK: Row plumbing

    private static let skillColumns = """
        SELECT id, name, description, instructions, created_at, updated_at
        FROM skills
    """

    private func skill(from stmt: OpaquePointer?) -> SkillRecord? {
        guard let id = string(stmt, 0), let name = string(stmt, 1) else { return nil }
        return SkillRecord(
            id: id,
            name: name,
            description: string(stmt, 2) ?? "",
            instructions: string(stmt, 3) ?? "",
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
        )
    }

    private func writeSkillRow(_ skill: SkillRecord) throws {
        try execBind("""
            INSERT INTO skills (id, name, description, instructions, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                description = excluded.description,
                instructions = excluded.instructions,
                created_at = MIN(skills.created_at, excluded.created_at),
                updated_at = excluded.updated_at
        """) { stmt in
            self.bind(stmt, 1, skill.id)
            self.bind(stmt, 2, skill.name)
            self.bind(stmt, 3, skill.description)
            self.bind(stmt, 4, skill.instructions)
            self.bind(stmt, 5, skill.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 6, skill.updatedAt.timeIntervalSinceReferenceDate)
        }
    }
}
