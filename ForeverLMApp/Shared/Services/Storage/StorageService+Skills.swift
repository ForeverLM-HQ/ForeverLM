import Foundation

/// Off-main access to the learner's chat skills (docs/chat-design.md,
/// "Skills"). Thin pass-throughs to `KnowledgeStore`; every write pushes to
/// the other Mac at once and tells the open windows to read the list again.
extension StorageService {

    func loadSkills() throws -> [SkillRecord] {
        try notebookFilesKnowledgeStore().loadSkills()
    }

    @discardableResult
    func createSkill(name: String, description: String, instructions: String) throws -> SkillRecord {
        let skill = try notebookFilesKnowledgeStore().createSkill(name: name, description: description, instructions: instructions)
        skillsDidChange()
        return skill
    }

    @discardableResult
    func updateSkill(_ skillID: String, name: String? = nil, description: String? = nil, instructions: String? = nil) throws -> SkillRecord {
        let skill = try notebookFilesKnowledgeStore().updateSkill(
            skillID,
            name: name,
            description: description,
            instructions: instructions
        )
        skillsDidChange()
        return skill
    }

    func deleteSkill(_ skillID: String) throws {
        try notebookFilesKnowledgeStore().deleteSkill(skillID)
        skillsDidChange()
    }

    private func skillsDidChange() {
        scheduleImmediateCloudKitSyncForDayPlans()
        NotificationCenter.default.post(name: .skillsDidChange, object: nil)
    }
}

extension Notification.Name {
    /// A skill was written on this Mac: `SkillLibrary` reads the list again.
    static let skillsDidChange = Notification.Name("foreverlm.skillsDidChange")
}
