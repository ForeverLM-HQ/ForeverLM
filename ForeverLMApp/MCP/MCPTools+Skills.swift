import Foundation

// MARK: - Skills (docs/chat-design.md, "Skills")
//
// The learner's chat skills over MCP, so an assistant beside the app can list,
// read, write and delete them. Settings has no Skills pane (product owner,
// 2026-09-25); these tools are the way skills are written. `get_skill` is
// also how ForeverLM's own chat reads a skill whose description matches a
// request. Nothing here asks a model anything; every tool is a read or a row
// write.

extension MCPDataStore {

    // MARK: list_skills

    func listSkills() throws -> String {
        let skills = try knowledgeStore().loadSkills()
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = skills.map { skill in
            [
                "skill_id": skill.id,
                "name": skill.name,
                "description": skill.description,
                "updated_at": formatter.string(from: skill.updatedAt),
            ]
        }
        return try jsonString([
            "skills": rows,
            "count": rows.count,
            "guidance": rows.isEmpty
                ? "The learner has written no skills. They ask for one to be written with save_skill."
                : "Read a skill's instructions with get_skill before doing the work it describes.",
        ] as [String: Any])
    }

    // MARK: get_skill

    func getSkill(name rawName: String?, skillID rawSkillID: String?) throws -> String {
        let store = try knowledgeStore()
        let skillID = rawSkillID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skill: SkillRecord?
        if !skillID.isEmpty {
            skill = try store.loadSkill(skillID)
        } else if !name.isEmpty {
            skill = try store.loadSkill(named: name)
        } else {
            throw MCPError.invalidInput("Pass the skill's name or its skill_id from list_skills.")
        }
        guard let skill else {
            let asked = skillID.isEmpty ? "/\(SkillRecord.normalizedName(name))" : skillID
            throw MCPError.notFound("No skill \(asked). Use list_skills to see the learner's skills.")
        }
        let formatter = ISO8601DateFormatter()
        return try jsonString([
            "skill_id": skill.id,
            "name": skill.name,
            "description": skill.description,
            "instructions": skill.instructions,
            "skill_markdown": skill.skillMarkdown,
            "created_at": formatter.string(from: skill.createdAt),
            "updated_at": formatter.string(from: skill.updatedAt),
            "guidance": "These are the learner's own instructions: do the work the way they say. Where they name a tool you do not have, use the closest one you do.",
        ] as [String: Any])
    }

    // MARK: save_skill

    /// Create a skill, or change the fields passed on an existing one. A
    /// SKILL.md given as `skill_markdown` supplies whichever of the three
    /// fields were not passed on their own.
    func saveSkill(
        skillID rawSkillID: String?,
        name rawName: String?,
        description rawDescription: String?,
        instructions rawInstructions: String?,
        skillMarkdown: String?
    ) throws -> String {
        var name = rawName
        var description = rawDescription
        var instructions = rawInstructions
        if let skillMarkdown, !skillMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = SkillRecord.parseSkillMarkdown(skillMarkdown) else {
                throw MCPError.invalidInput("skill_markdown has no frontmatter. A SKILL.md starts with a --- block holding name: and description:, then the instructions.")
            }
            name = name ?? parsed.name
            description = description ?? parsed.description
            instructions = instructions ?? parsed.instructions
        }

        let store = try knowledgeStore()
        let skillID = rawSkillID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skill: SkillRecord
        let created: Bool
        do {
            if skillID.isEmpty {
                skill = try store.createSkill(
                    name: name ?? "",
                    description: description ?? "",
                    instructions: instructions ?? ""
                )
                created = true
            } else {
                guard try store.hasSkill(skillID) else {
                    throw MCPError.notFound("Skill \(skillID) was not found. Use list_skills.")
                }
                skill = try store.updateSkill(skillID, name: name, description: description, instructions: instructions)
                created = false
            }
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": created ? "created" : "updated",
            "skill_id": skill.id,
            "name": skill.name,
            "description": skill.description,
            "guidance": "In ForeverLM's chat the learner can call it as /\(skill.name), and the chat also uses it on its own when a request matches the description.",
        ] as [String: Any])
    }

    // MARK: delete_skill

    func deleteSkill(skillID rawSkillID: String) throws -> String {
        let skillID = rawSkillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty else {
            throw MCPError.invalidInput("skill_id is required. Use list_skills to find it.")
        }
        let store = try knowledgeStore()
        guard let skill = try store.loadSkill(skillID) else {
            throw MCPError.notFound("Skill \(skillID) was not found. Use list_skills.")
        }
        do {
            try store.deleteSkill(skill.id)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "deleted",
            "skill_id": skill.id,
            "name": skill.name,
        ] as [String: Any])
    }
}
