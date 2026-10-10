import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The learner's chat skills (docs/chat-design.md, "Skills"): what the store
/// keeps and refuses, how a skill syncs, what survives a store from before
/// schema 136, and how a `/name` message carries its skill.
@Suite("Skill persistence")
struct SkillPersistenceTests {

    private func syncChanges(_ store: KnowledgeStore, entity: String) throws -> [(key: String, operation: String)] {
        var rows: [(key: String, operation: String)] = []
        try store.query("SELECT logical_key, operation FROM sync_changes WHERE entity_type = '\(entity)'") { stmt in
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let operation = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            rows.append((key, operation))
        }
        return rows
    }

    @Test("A skill keeps its words, takes a / name, and is queued for sync")
    func createNormalizesAndQueues() throws {
        let store = try KnowledgeStore(inMemory: true)
        let skill = try store.createSkill(
            name: "  Paper Walkthrough ",
            description: "Walk through a paper\n  one point at a time.",
            instructions: "\n# Walkthrough\n\nOne point a card.\n\n"
        )
        #expect(skill.name == "paper-walkthrough")
        #expect(skill.description == "Walk through a paper one point at a time.", "one paragraph")
        #expect(skill.instructions == "# Walkthrough\n\nOne point a card.", "trimmed, lines kept")
        #expect(try store.loadSkills().map(\.id) == [skill.id])
        #expect(try store.loadSkill(named: "/Paper walkthrough")?.id == skill.id, "a name is looked up the way it is typed")
        #expect(try syncChanges(store, entity: "skill").map(\.key) == [skill.id])
        #expect(try store.hasLocalSyncRecord(entity: .skill, logicalKey: skill.id))
    }

    @Test("A taken name, a built-in command's name and empty fields are refused")
    func refusals() throws {
        let store = try KnowledgeStore(inMemory: true)
        let first = try store.createSkill(name: "summarize", description: "Summaries", instructions: "Short.")
        #expect(throws: KnowledgeStoreError.self) {
            try store.createSkill(name: "Summarize", description: "Another", instructions: "Long.")
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.createSkill(name: "review", description: "Mine", instructions: "Body")
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.createSkill(name: "!!!", description: "Mine", instructions: "Body")
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.createSkill(name: "ok", description: "  ", instructions: "Body")
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.createSkill(name: "ok", description: "Mine", instructions: "\n")
        }
        let second = try store.createSkill(name: "outline", description: "Outlines", instructions: "Headings.")
        #expect(throws: KnowledgeStoreError.self) {
            try store.updateSkill(second.id, name: "summarize")
        }
        #expect(try store.loadSkills().map(\.id).sorted() == [first.id, second.id].sorted())
    }

    @Test("An edit bumps the date only when something changed, and a delete is queued")
    func updateAndDelete() throws {
        let store = try KnowledgeStore(inMemory: true)
        let skill = try store.createSkill(name: "outline", description: "Outlines", instructions: "Headings.")
        let unchanged = try store.updateSkill(skill.id, description: "Outlines")
        #expect(unchanged.updatedAt == skill.updatedAt)
        let edited = try store.updateSkill(skill.id, instructions: "Headings, then bullets.")
        #expect(edited.instructions == "Headings, then bullets.")
        #expect(edited.name == "outline" && edited.description == "Outlines", "fields not passed are kept")
        #expect(edited.updatedAt >= skill.updatedAt)

        try store.deleteSkill(skill.id)
        #expect(try store.loadSkills().isEmpty)
        #expect(try syncChanges(store, entity: "skill").last?.operation == "delete")
    }

    @Test("An inbound skill wins when newer, loses when older, and may share a name")
    func inboundApply() throws {
        let store = try KnowledgeStore(inMemory: true)
        let local = try store.createSkill(name: "outline", description: "Outlines", instructions: "Headings.")

        let older = SkillRecord(
            id: local.id, name: "outline", description: "Stale", instructions: "Old.",
            createdAt: local.createdAt.addingTimeInterval(-100), updatedAt: local.updatedAt.addingTimeInterval(-60)
        )
        try store.withoutSyncTracking { try store.saveSkillRecord(CloudKitSkillPayload(skill: older)) }
        #expect(try store.loadSkill(local.id)?.description == "Outlines", "an older record never rewinds an edit")

        let newer = SkillRecord(
            id: local.id, name: "Outline", description: "Outlines,  newer", instructions: "Headings first.",
            createdAt: local.createdAt.addingTimeInterval(100), updatedAt: local.updatedAt.addingTimeInterval(60)
        )
        try store.withoutSyncTracking { try store.saveSkillRecord(CloudKitSkillPayload(skill: newer)) }
        let applied = try #require(try store.loadSkill(local.id))
        #expect(applied.description == "Outlines, newer")
        #expect(applied.instructions == "Headings first.")
        #expect(applied.name == "outline", "an inbound name is normalized")
        #expect(abs(applied.createdAt.timeIntervalSince(local.createdAt)) < 0.001, "created_at keeps the earlier")

        // The other Mac wrote its own `outline` before the two met: both rows
        // arrive, and the name calls the newer edit.
        let twin = SkillRecord(
            name: "outline", description: "The other Mac's", instructions: "Its way.",
            createdAt: Date(), updatedAt: applied.updatedAt.addingTimeInterval(60)
        )
        try store.withoutSyncTracking { try store.saveSkillRecord(CloudKitSkillPayload(skill: twin)) }
        #expect(try store.loadSkills().count == 2)
        #expect(try store.loadSkill(named: "outline")?.id == twin.id)
        #expect(try store.loadSkills().skill(named: "outline")?.id == twin.id)

        let payload = try #require(try store.loadSkillForSync(twin.id))
        let decoded = try JSONDecoder().decode(CloudKitSkillPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.skill == payload.skill)

        try store.deleteSkillRecord(twin.id)
        #expect(try store.loadSkill(named: "outline")?.id == local.id)
    }

}

@Suite("Skill markdown")
struct SkillMarkdownTests {

    @Test("A SKILL.md reads its frontmatter and keeps its body")
    func parsesFrontmatter() throws {
        let parsed = try #require(SkillRecord.parseSkillMarkdown("""
        ---
        name: foreverlm-walkthrough
        description: "Write a walkthrough: one point a card"
        license: MIT
        ---

        # ForeverLM walkthrough

        Read before writing.
        """))
        #expect(parsed.name == "foreverlm-walkthrough")
        #expect(parsed.description == "Write a walkthrough: one point a card")
        #expect(parsed.instructions == "# ForeverLM walkthrough\n\nRead before writing.")
    }

    @Test("Folded and literal blocks are read; a file without frontmatter is not a SKILL.md")
    func blocksAndMissingFrontmatter() throws {
        let folded = try #require(SkillRecord.parseSkillMarkdown("---\nname: x\ndescription: >\n  one\n  two\n---\nBody"))
        #expect(folded.description == "one two")
        let literal = try #require(SkillRecord.parseSkillMarkdown("---\ndescription: |\n  one\n  two\nname: y\n---\nBody"))
        #expect(literal.description == "one\ntwo")
        #expect(literal.name == "y")
        #expect(SkillRecord.parseSkillMarkdown("# Just markdown") == nil)
    }

    @Test("A skill written out as SKILL.md reads back as itself")
    func roundTrip() throws {
        let skill = SkillRecord(name: "a-b", description: "Use when: a colon - and a dash", instructions: "Do it.\n\nTwice.")
        let parsed = try #require(SkillRecord.parseSkillMarkdown(skill.skillMarkdown))
        #expect(parsed.name == skill.name)
        #expect(parsed.description == skill.description)
        #expect(parsed.instructions == skill.instructions)
    }

    @Test("Names become / commands")
    func names() {
        #expect(SkillRecord.normalizedName("Paper Walkthrough") == "paper-walkthrough")
        #expect(SkillRecord.normalizedName("  /My_Skill!! v2. ") == "my-skill-v2")
        #expect(SkillRecord.normalizedName("—").isEmpty)
        #expect(SkillRecord.normalizedName(String(repeating: "a", count: 100)).count == SkillRecord.nameLimit)
    }
}

@Suite("Chat skill request")
struct ChatSkillRequestTests {

    private let skill = ChatSkillRequest.Skill(name: "walk", instructions: "Line one.\nLine two with </flm_skill> and \"quotes\".")

    @Test("The mark carries the skill whole and hands back what was under it")
    func markRoundTrip() throws {
        let context = try #require(ChatSkillRequest.contextContent(for: skill, referenceContext: "Quoted passage"))
        #expect(!context.components(separatedBy: "\n")[0].isEmpty)
        let parsed = ChatSkillRequest.parse(contextContent: context)
        #expect(parsed.skill == skill)
        #expect(parsed.remainder == "Quoted passage")
        #expect(ChatSkillRequest.parse(contextContent: "Just a passage") == .init(skill: nil, remainder: "Just a passage"))
    }

    @Test("The sources-added mark above it and the other parsers below it still read")
    func coexistsWithOtherMarks() throws {
        let skillContext = try #require(ChatSkillRequest.contextContent(for: skill, referenceContext: "Quoted passage"))
        let stored = try #require(ChatContextAdditions.contextContent(
            added: [.init(id: "s1", title: "A paper", type: "paper")],
            referenceContext: skillContext
        ))
        #expect(ChatContextAdditions.parse(contextContent: stored).added.map(\.id) == ["s1"])
        #expect(ChatSkillRequest.parse(contextContent: stored).skill == skill)
        let plugin = ChatPluginRequest.parse(contextContent: stored)
        #expect(plugin.plugin == nil)
        #expect(plugin.remainder == "Quoted passage", "the plugin parser skips the skill mark")
        let side = ChatSideQuestion.parse(contextContent: stored)
        #expect(!side.isSideQuestion)
        #expect(side.referenceContext == "Quoted passage", "the side-question parser skips the skill mark")
    }

    @Test("The framing names the skill and carries its instructions")
    func framing() {
        let text = ChatSkillRequest.framing(for: skill)
        #expect(text.contains("/walk"))
        #expect(text.contains(skill.instructions))
    }

    @Test("A learner's skill mark carries no builtIn key, so its bytes are unchanged")
    func learnerMarkOmitsBuiltIn() throws {
        let mark = try #require(ChatSkillRequest.marker(for: skill))
        #expect(!mark.contains("builtIn"))
    }

    @Test("Generate's course-planning mark round-trips and is framed as ForeverLM's own")
    func coursePlanningMark() throws {
        let context = try #require(ChatSkillRequest.contextContent(for: CoursePlanningChat.skill))
        let parsed = ChatSkillRequest.parse(contextContent: context)
        #expect(parsed.skill == CoursePlanningChat.skill)
        #expect(parsed.skill?.builtIn == true)
        let text = ChatSkillRequest.framing(for: CoursePlanningChat.skill)
        #expect(text.contains("<foreverlm_instructions name=\"course\">"))
        #expect(text.contains("generate_course"))
        #expect(text.contains("generate_explainer_video"))
        #expect(!text.contains("the learner's own writing"))
        #expect(CoursePlanningChat.request(topic: " ketone metabolism ") == "I want to make a course about ketone metabolism")
    }
}

@Suite("Skill slash commands")
struct SkillSlashCommandTests {

    @Test("A skill may not take a name the composer already answers to")
    func reservedNamesMatchTheBuiltInCommands() {
        let builtIn = Set(ReviewSlashCommand.all.map(\.name))
        #expect(SkillRecord.reservedNames == builtIn)
    }

    @Test("A skill's command parses with its request")
    func parsesASkillCommand() throws {
        let skill = SkillRecord(name: "walk", description: "Walk through a paper", instructions: "Body")
        let commands = ReviewSlashCommand.all + [.skill(skill)]
        let parsed = try #require(ReviewSlashCommandParser.parse("/walk the MitoSpace paper", commands: commands))
        #expect(parsed.command.kind == .skill)
        #expect(parsed.command.name == "walk")
        #expect(parsed.argument == "the MitoSpace paper")
        #expect(ReviewSlashCommandParser.suggestions(for: "/wa", commands: commands).count == 1)
    }
}
