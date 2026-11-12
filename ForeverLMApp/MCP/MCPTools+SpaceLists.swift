#if os(macOS)
import Foundation

// MARK: - Lists in the Space over MCP
//
// The learner's lists of goals and of ideas, items in their Space beside the
// pages, as ChatGPT's To-do list is (docs/docs-design.md, "Lists in the
// Space"). These tools list them with what each holds, make one, and rename,
// file, pin, fill, trash or delete one, each on the learner's word, as the
// Space's own menus do. The goals and ideas stay records of their own
// (list_goals, list_ideas); a list is the learner's grouping of them, kept in
// synced rows the Mac writes, so the tools need the Mac.

extension MCPToolRegistry {
    static var spaceListToolDefs: [MCPToolDef] {
        let itemIDs: [String: Any] = [
            "type": "array",
            "items": ["type": "string"],
            "description": "Goal IDs from list_goals for a goals list, or Idea IDs from list_ideas for an ideas list.",
        ]
        return [
            MCPToolDef(
                name: "list_space_lists",
                description: "List the learner's lists in their Space: lists of goals and lists of ideas, items beside their pages and canvases, each filed in at most one of their spaces. Returns each list's list_id, kind (goals or ideas), name, created_at, the space it is in (space_id and name) if any, whether it is pinned, whether it is in Trash, and what it holds: for a goals list each goal's goal_id, title, deadline and status; for an ideas list each idea's idea_id, title and whether it is open. A goal or an idea is in one list at most and stays listed by list_goals or list_ideas whatever list it is in. Pass include_trash to list the lists in Trash too.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_trash": ["type": "boolean", "description": "Also list the lists in Trash. Defaults to false."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_space_list",
                description: "Make a list in the learner's Space on their word (\"make a list of my goals for the thesis\"): kind goals or ideas, named as they say, filed in one of their spaces when they name one (space_id from list_spaces), and holding item_ids when given, each moved out of any list it was in. To put a new goal or idea in it, make the goal (create_learning_goal) or the idea (create_idea) first, then pass its id here or to update_space_list. Returns the list.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["goals", "ideas"], "description": "What the list holds."],
                        "name": ["type": "string", "description": "The list's name. Defaults to Goals or Ideas."],
                        "space_id": ["type": "string", "description": "Optional space ID from list_spaces to file the list in."],
                        "item_ids": itemIDs,
                    ],
                    "required": ["kind"],
                ]
            ),
            MCPToolDef(
                name: "update_space_list",
                description: "Change one of the learner's lists in their Space on their word, as its menu does: rename it (name), file it in one of their spaces (space_id from list_spaces) or take it out of every space (space_id \"\"), pin or unpin it in the Space sidebar (pinned), move it to Trash or restore it (in_trash), put goals or ideas in it (add_item_ids, each moved out of any list it was in) or take them out (remove_item_ids). A goal goes only in a goals list and an idea only in an ideas list. Pass only what changes; the goals and ideas themselves are not changed. Returns the list as it is now.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "list_id": ["type": "string", "description": "List ID from list_space_lists."],
                        "name": ["type": "string", "description": "Its new name."],
                        "space_id": ["type": "string", "description": "A space ID from list_spaces to move it into, or \"\" to take it out of every space."],
                        "pinned": ["type": "boolean", "description": "Pin it in the Space sidebar (true) or unpin it (false)."],
                        "in_trash": ["type": "boolean", "description": "Move it to Trash (true) or restore it from Trash (false)."],
                        "add_item_ids": itemIDs,
                        "remove_item_ids": itemIDs,
                    ],
                    "required": ["list_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_space_list",
                description: "Delete a list from the learner's Space forever, on their explicit word: the list, its place in a space and its pin go, on every device. The goals and ideas it held are not deleted; they stay in Goals and Ideas, in no list. Only a list already in Trash can be deleted (update_space_list with in_trash true first), as in the Space. This cannot be undone.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "list_id": ["type": "string", "description": "List ID from list_space_lists, of a list in Trash."],
                    ],
                    "required": ["list_id"],
                ]
            ),
        ]
    }
}

extension MCPDataStore {
    func executeSpaceListTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "list_space_lists":
            return try jsonString(try await Self.listSpaceLists(includeTrash: arguments["include_trash"] as? Bool ?? false))
        case "create_space_list":
            guard let rawKind = Self.nilIfBlank(arguments["kind"] as? String ?? ""),
                  let kind = SpaceList.Kind(rawValue: rawKind) else {
                throw MCPError.invalidInput("kind must be goals or ideas.")
            }
            return try jsonString(try await Self.createSpaceList(
                kind: kind,
                name: Self.nilIfBlank(arguments["name"] as? String ?? ""),
                spaceID: Self.nilIfBlank(arguments["space_id"] as? String ?? ""),
                itemIDs: Self.stringList(arguments["item_ids"])
            ))
        case "update_space_list":
            return try jsonString(try await Self.updateSpaceList(id: try Self.spaceListID(arguments), arguments: arguments))
        case "delete_space_list":
            return try jsonString(try await Self.deleteSpaceList(id: try Self.spaceListID(arguments)))
        default:
            return nil
        }
    }

    private static func spaceListID(_ arguments: [String: Any]) throws -> String {
        guard let id = nilIfBlank(arguments["list_id"] as? String ?? "") else {
            throw MCPError.invalidInput("list_id is required: list_space_lists gives each list's id.")
        }
        return id
    }

    private static func stringList(_ raw: Any?) -> [String] {
        (raw as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The goals and ideas a list's tools read, loaded once.
    @MainActor
    private static func preparedStudio() async throws -> StudioViewModel {
        let studio = try AppModelBridge.requireStudio()
        if !studio.hasLoadedLearningGoalsOnce { await studio.loadLearningGoals() }
        if !studio.hasLoadedIdeasOnce { await studio.loadIdeas() }
        studio.refreshSpaceListsFromRows()
        studio.refreshPageSpacesFromRows()
        return studio
    }

    /// One list as the tools answer it, with what it holds.
    @MainActor
    static func spaceListEntry(_ list: SpaceList, in studio: StudioViewModel) -> [String: Any] {
        var entry: [String: Any] = [
            "list_id": list.id,
            "kind": list.kind.rawValue,
            "name": list.name,
            "created_at": iso8601String(list.createdAt),
            "in_trash": list.isTrashed,
            "pinned": studio.isPagePinned(list.id),
        ]
        if let space = studio.pageSpace(ofPage: list.id) {
            entry["space"] = ["space_id": space.id, "name": space.name]
        }
        switch list.kind {
        case .goals:
            let goals = studio.goals(inSpaceList: list.id)
            entry["goals"] = goals.map { goal -> [String: Any] in
                [
                    "goal_id": goal.id,
                    "title": goal.title,
                    "deadline": iso8601String(goal.endAt),
                    "status": goal.isArchived ? "archived" : goal.isDone ? "done" : "active",
                ]
            }
            entry["count"] = goals.count
        case .ideas:
            let ideas = studio.ideas(inSpaceList: list.id)
            entry["ideas"] = ideas.map { idea -> [String: Any] in
                ["idea_id": idea.id, "title": idea.title, "open": idea.isOpen]
            }
            entry["count"] = ideas.count
        }
        return entry
    }

    @MainActor
    private static func existingSpaceList(_ id: String, in studio: StudioViewModel) throws -> SpaceList {
        studio.refreshSpaceListsFromRows()
        guard let list = studio.spaceLists.list(id) else {
            throw MCPError.notFound("No list has list_id \(id); list_space_lists lists them.")
        }
        return list
    }

    /// The ids that are records of the list's kind, or why one is not.
    @MainActor
    private static func checkedItemIDs(_ ids: [String], for kind: SpaceList.Kind, in studio: StudioViewModel) throws -> [String] {
        let known: Set<String>
        switch kind {
        case .goals: known = Set(studio.allGoals.map(\.id))
        case .ideas: known = Set(studio.ideas.map(\.id))
        }
        let unknown = ids.filter { !known.contains($0) }
        guard unknown.isEmpty else {
            let source = kind == .goals ? "list_goals" : "list_ideas"
            throw MCPError.invalidInput("A \(kind.rawValue) list holds only \(kind.pluralNoun); these are not \(kind.pluralNoun) here: \(unknown.prefix(10).joined(separator: ", ")). \(source) lists them.")
        }
        return ids
    }

    @MainActor
    private static func checkedSpaceID(_ spaceID: String, in studio: StudioViewModel) throws {
        guard studio.pageSpaces.space(spaceID) != nil else {
            throw MCPError.notFound("No space has space_id \(spaceID); list_spaces lists them.")
        }
    }

    @MainActor
    static func listSpaceLists(includeTrash: Bool) async throws -> [String: Any] {
        let studio = try await preparedStudio()
        let lists = studio.spaceLists.all.filter { includeTrash || !$0.isTrashed }
        return ["lists": lists.map { spaceListEntry($0, in: studio) }, "count": lists.count]
    }

    @MainActor
    static func createSpaceList(kind: SpaceList.Kind, name: String?, spaceID: String?, itemIDs: [String]) async throws -> [String: Any] {
        let studio = try await preparedStudio()
        guard studio.activeTeamID == nil else {
            throw MCPError.invalidInput("A team's library holds no lists of the learner's: switch to My Library first.")
        }
        if let spaceID { try checkedSpaceID(spaceID, in: studio) }
        let items = try checkedItemIDs(itemIDs, for: kind, in: studio)
        let list = studio.createSpaceList(kind, named: name, inPageSpace: spaceID, holding: items)
        return ["list": spaceListEntry(list, in: studio)]
    }

    @MainActor
    static func updateSpaceList(id: String, arguments: [String: Any]) async throws -> [String: Any] {
        let studio = try await preparedStudio()
        let list = try existingSpaceList(id, in: studio)
        let name = (arguments["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name, SpaceLists.cleanedName(name) == nil {
            throw MCPError.invalidInput("name has nothing in it.")
        }
        let spaceID = (arguments["space_id"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let spaceID, !spaceID.isEmpty { try checkedSpaceID(spaceID, in: studio) }
        let adding = try checkedItemIDs(stringList(arguments["add_item_ids"]), for: list.kind, in: studio)
        let removing = stringList(arguments["remove_item_ids"]).filter { studio.spaceLists.listID(of: $0) == id }

        if let inTrash = arguments["in_trash"] as? Bool {
            if inTrash { studio.moveSpaceListsToTrash([id]) } else { studio.restoreSpaceLists([id]) }
        }
        if let name { studio.renameSpaceList(id, to: name) }
        if let spaceID { studio.filePages([id], inPageSpace: spaceID.isEmpty ? nil : spaceID) }
        if let pinned = arguments["pinned"] as? Bool { studio.setPagePinned(id, pinned: pinned) }
        if !adding.isEmpty { studio.fileRecords(adding, inSpaceList: id) }
        if !removing.isEmpty { studio.fileRecords(removing, inSpaceList: nil) }
        return ["list": spaceListEntry(try existingSpaceList(id, in: studio), in: studio)]
    }

    @MainActor
    static func deleteSpaceList(id: String) async throws -> [String: Any] {
        let studio = try await preparedStudio()
        let list = try existingSpaceList(id, in: studio)
        guard list.isTrashed else {
            throw MCPError.invalidInput("\(list.name) is not in Trash. Move it there first (update_space_list with in_trash true); only a list in Trash is deleted forever.")
        }
        studio.deleteSpaceListsForever([id])
        return ["deleted": true, "list_id": id, "name": list.name]
    }
}
#endif
