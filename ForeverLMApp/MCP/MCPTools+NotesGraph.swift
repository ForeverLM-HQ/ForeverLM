#if os(macOS)
import Foundation

// MARK: - The notes graph over MCP (docs/notes-graph-design.md, "MCP")
//
// Roam Research's note taking inside Docs, for an assistant: what points at
// a page, an Idea, a source or one block (`get_linked_references`), one block
// by its id (`get_block`), the learner's page a day (`get_daily_note`,
// `append_to_daily_note`), and their plan for a quarter or a week
// (`get_plan`, a Page the same way: `PlanPeriod`). `read_doc` takes `resolve_references` to read a
// Doc with its references replaced by their words (MCPTools+Artifacts.swift).
//
// Everything is answered from the Docs' stored Markdown through the storage
// actor (`StorageService+DocGraph.swift`), never the cached connection, so
// none of these holds the store gate. None spends AI money. All need the
// learner's Mac: they read its library.

extension MCPToolRegistry {
    static var notesGraphToolDefs: [MCPToolDef] {
        let blockID: [String: Any] = [
            "type": "string",
            "description": "A block's id: the nine lowercase letters and digits it ends with as ` ^id`, the id ((id)) names. ((id)) and ^id are read too.",
        ]
        let teamID: [String: Any] = [
            "type": "string",
            "description": "Team ID from list_teams, for a source or a block in a team's library. Omit for My Library.",
        ]
        let date: [String: Any] = [
            "type": "string",
            "description": "The day, as YYYY-MM-DD (\"2026-10-06\"), or today, yesterday or tomorrow. Defaults to today where the learner's Mac is.",
        ]
        return [
            MCPToolDef(
                name: "get_linked_references",
                description: "Read the Linked References of a page, an Idea, a source or one block in the learner's Docs: what points at it, as Roam Research lists it under a page. Pass exactly one of doc_id, idea_id, source_id or block_id. Answers with the pages that point there, newest edit first: each page's kind (doc, dailyNote or idea), id and title, and the blocks in it that point, each with its Markdown, plain text, block_id (null until something references the block), breadcrumbs (the bullets and heading it sits under, outermost first) and the Markdown nested under it. The Ideas linked to a Doc or a source come as idea pages without blocks. include_unlinked (doc_id only) adds the Unlinked References: blocks of other Docs that write the page's title without linking it. A team Doc's references are its team's Docs. The grammar a block points with: [Title](foreverlm://doc/<id>), [[Title]], #tag and #[[Two words]] name a page (a daily note's title is its day written out, \"October 6th, 2026\"); [Title](foreverlm://idea/<id>) an Idea; a foreverlm://source/<id> link or the source's web address cites a source; ((id)) references a block and {{embed: ((id))}} on a line of its own embeds it, where id is the nine lowercase letters and digits the block ends with as ` ^id`. Read-only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs, or a daily note's doc_id from get_daily_note."],
                        "idea_id": ["type": "string", "description": "Idea ID from list_ideas."],
                        "source_id": ["type": "string", "description": "Source ID from list_sources or a search."],
                        "block_id": blockID,
                        "team_id": teamID,
                        "include_unlinked": [
                            "type": "boolean",
                            "description": "With doc_id: also list the Unlinked References, each block with start and end, the UTF-16 offsets of the title's words in its markdown. Defaults to false.",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Most pages listed, and most unlinked references (default 50, at most 200).",
                        ],
                    ] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_block",
                description: "Read one block of the learner's Docs by its id: the nine lowercase letters and digits a block ends with as ` ^id` (hidden in the editor), which ((id)) references and {{embed: ((id))}} embeds from other Docs. Answers with the Doc that holds it (doc_id, doc_title, and day for a daily note), the block's own Markdown without its id, its plain text and kind (paragraph, heading, listItem or quote), its breadcrumbs (the bullets and heading it sits under, outermost first), the Markdown nested under it, and how many times it is referenced or embedded. Use it to read what a ((id)) says; read_doc with resolve_references reads a whole Doc with every reference replaced by its words, and get_linked_references with block_id lists where the block is referenced. Read-only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "block_id": blockID,
                        "team_id": teamID,
                    ] as [String: Any],
                    "required": ["block_id"],
                ]
            ),
            MCPToolDef(
                name: "get_daily_note",
                description: "Read the learner's daily note: Roam Research's page a day, kept in Docs. A daily note is an ordinary Markdown Doc in My Library whose id is daily-YYYY-MM-DD and whose title is the day written out (\"October 6th, 2026\"), so [[October 6th, 2026]] in any Doc links it, and read_doc, edit_doc and get_linked_references take its doc_id. Answers with its doc_id, title, Markdown and revision, or says the day has no note. Writes nothing unless create is true, which makes the day's empty note when there is none, as opening the day in ForeverLM does. To write in a day, use append_to_daily_note.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": date,
                        "create": [
                            "type": "boolean",
                            "description": "Make the day's empty note when there is none. Defaults to false: the call only reads.",
                        ],
                    ] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_plan",
                description: "Read the learner's plan for a quarter or a week, planned as Cal Newport teaches it: a quarter's bigger picture, its few objectives and the strategies and habits that serve them, and a week's progress and a line per day, written with the quarter's plan and the calendar in view; the day is planned into the Mac's Calendar instead (get_calendar_events, create_calendar_event). A plan is an ordinary Markdown Doc in My Library whose id names its period (plan-2026-q4, plan-2026-w45: ISO weeks, Monday to Sunday) and whose title is \"Q4 2026\" or \"Week of November 2nd, 2026\", so [[Q4 2026]] in any Doc links it, and read_doc, edit_doc and get_linked_references take its doc_id. Answers with its doc_id, title, the days it spans, its Markdown and revision, or says the period has no plan yet; with the week's quarter (doc_id, title and Markdown) for a week, and the quarter's weeks and whether each is planned for a quarter. Writes nothing unless create is true, which makes the plan from its template (a quarter's Big picture, Objectives, and Strategies and habits; a week's link to its quarter, This week and Days) when there is none, as opening it in ForeverLM's Plan place does. Write in it with edit_doc, keeping its headings.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "scale": [
                            "type": "string",
                            "enum": PlanScale.allCases.map(\.rawValue),
                            "description": "quarter or week.",
                        ],
                        "date": [
                            "type": "string",
                            "description": "Which quarter or week: any day in it as YYYY-MM-DD, its key (\"2026-Q4\", \"2026-W45\") or its title (\"Q4 2026\"), or this, next or last. Defaults to the present one where the learner's Mac is.",
                        ],
                        "create": [
                            "type": "boolean",
                            "description": "Make the plan from its template when there is none. Defaults to false: the call only reads.",
                        ],
                    ] as [String: Any],
                    "required": ["scale"],
                ]
            ),
            MCPToolDef(
                name: "append_to_daily_note",
                description: "Add Markdown to the end of the learner's daily note (today's unless date names another day), making the note when the day has none: the way to jot a thought, a finding or a task into the day, as in Roam Research's Daily Notes. The Markdown lands as its own block or blocks after everything already there (bullets that follow bullets join the list; anything else starts after a blank line). Nothing already in the note changes, and the write is checked against the note's revision, so a line the learner is typing at that moment is kept. Write in the notes grammar: [[Title]], #tag or #[[Two words]] name a page by its title, [Title](foreverlm://doc/<id>) links a Doc and [Title](foreverlm://idea/<id>) an Idea, a foreverlm://source/<id> link or a paper's web address cites a source, and ((id)) references a block, reading as its words, by the id get_block and get_linked_references give. Answers with the note's doc_id, title and new revision.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "markdown": [
                            "type": "string",
                            "description": "The Markdown to add, e.g. \"- Finished the methods of [[Mitophagy in neurons]]\".",
                        ],
                        "date": date,
                    ] as [String: Any],
                    "required": ["markdown"],
                ]
            ),
        ]
    }

    static let notesGraphToolNames: Set<String> = [
        "get_linked_references", "get_block", "get_daily_note", "append_to_daily_note", "get_plan",
    ]
}

extension MCPDataStore {
    func executeNotesGraphTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "get_linked_references":
            return try jsonString(try await notesGraphLinkedReferences(arguments: arguments))
        case "get_block":
            return try jsonString(try await notesGraphBlock(arguments: arguments))
        case "get_daily_note":
            return try jsonString(try await dailyNote(arguments: arguments))
        case "append_to_daily_note":
            return try jsonString(try await appendToDailyNote(arguments: arguments))
        case "get_plan":
            return try jsonString(try await plan(arguments: arguments))
        default:
            return nil
        }
    }

    // MARK: get_linked_references

    /// What `get_linked_references` was asked about.
    struct NotesGraphReferenceRequest: Equatable {
        let target: DocGraphTarget
        let includeUnlinked: Bool
    }

    /// Exactly one target, as the description says; a blank argument is no
    /// argument, and `include_unlinked` belongs to a Doc.
    static func notesGraphReferenceRequest(from arguments: [String: Any]) throws -> NotesGraphReferenceRequest {
        func text(_ key: String) -> String? {
            guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        var targets: [DocGraphTarget] = []
        if let raw = text("doc_id") {
            if case .doc(let id)? = StudioEntityLink.parse(destination: raw) { targets.append(.doc(id)) } else { targets.append(.doc(raw)) }
        }
        if let raw = text("idea_id") {
            if case .idea(let id)? = StudioEntityLink.parse(destination: raw) { targets.append(.idea(id)) } else { targets.append(.idea(raw)) }
        }
        if let raw = text("source_id") {
            targets.append(.source(raw))
        }
        if let raw = text("block_id") {
            guard let id = notesGraphBlockID(raw) else {
                throw MCPError.invalidInput("block_id must be a block's id: nine lowercase letters and digits, the ` ^id` a block ends with or what ((id)) names. \(raw) is not one.")
            }
            targets.append(.block(id))
        }
        guard targets.count == 1, let target = targets.first else {
            throw MCPError.invalidInput(
                targets.isEmpty
                    ? "get_linked_references needs one of doc_id, idea_id, source_id or block_id."
                    : "get_linked_references takes exactly one of doc_id, idea_id, source_id or block_id; \(targets.count) were given. Ask about each in a call of its own."
            )
        }
        let includeUnlinked = arguments["include_unlinked"] as? Bool ?? false
        if includeUnlinked {
            guard case .doc = target else {
                throw MCPError.invalidInput("include_unlinked goes with doc_id only: the Unlinked References of a page are where other Docs write its title without linking it.")
            }
        }
        return NotesGraphReferenceRequest(target: target, includeUnlinked: includeUnlinked)
    }

    /// A block id as an assistant may quote it: bare, as `((id))` or as the
    /// `^id` marker. Nil when it is not nine letters and digits.
    static func notesGraphBlockID(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("(("), text.hasSuffix("))") {
            text = String(text.dropFirst(2).dropLast(2))
        }
        if text.hasPrefix("^") { text = String(text.dropFirst()) }
        text = text.trimmingCharacters(in: .whitespaces).lowercased()
        return DocGraphSyntax.isBlockID(text) ? text : nil
    }

    func notesGraphLinkedReferences(arguments: [String: Any]) async throws -> [String: Any] {
        let request = try Self.notesGraphReferenceRequest(from: arguments)
        let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 50, 1), 200)
        let namedTeamID = (arguments["team_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitTeamID = namedTeamID?.isEmpty == false ? namedTeamID : nil
        let storage = notebookFileStorage

        // The target's own library answers: a Doc's is its own, an Idea's is
        // My Library, a source's is the one it is in unless a team is named.
        let teamID: String?
        var target: [String: Any]
        switch request.target {
        case .doc(let id):
            guard let doc = try await storage.loadArtifact(id) else {
                throw MCPError.notFound("No Doc has the id \(id). list_docs lists the Docs, and get_daily_note gives a daily note's doc_id.")
            }
            teamID = doc.teamID
            target = ["kind": DailyNote.isDailyNoteID(id) ? "dailyNote" : "doc", "id": id, "title": doc.title]
        case .idea(let id):
            guard let idea = try await storage.loadIdeas().first(where: { $0.id == id }) else {
                throw MCPError.notFound("No Idea has the id \(id). list_ideas lists them.")
            }
            teamID = nil
            target = ["kind": "idea", "id": id, "title": idea.title]
        case .source(let id):
            guard let source = try await storage.loadSourceWithoutContent(id) else {
                throw MCPError.notFound("No source has the id \(id). list_sources or a search gives source ids.")
            }
            teamID = explicitTeamID ?? source.teamID
            target = ["kind": "source", "id": id, "title": source.title]
        case .block(let id):
            teamID = explicitTeamID
            guard let block = try await storage.docGraphBlocks([id], teamID: teamID)[id] else {
                throw MCPError.notFound(Self.blockNotFoundMessage(id, teamID: teamID))
            }
            target = ["kind": "block", "id": id, "doc_id": block.docID, "plain_text": block.plainText]
        }
        if let teamID { target["team_id"] = teamID }

        let groups = try await storage.docGraphLinkedReferences(to: request.target, teamID: teamID)
        let listed = Array(groups.prefix(limit))
        var payload: [String: Any] = [
            "target": target,
            "page_count": groups.count,
            "block_count": groups.reduce(0) { $0 + $1.blocks.count },
            "pages": listed.map(Self.notesGraphPagePayload),
            "guidance": "Each block's markdown is as the Doc stores it: ((id)) is a block reference (get_block reads it), [[Title]] and #tag name pages by title. Open a page with read_doc and its id; a block_id is null until something references that block.",
        ]
        if listed.count < groups.count {
            payload["pages_not_listed"] = groups.count - listed.count
        }
        if request.includeUnlinked, case .doc(let id) = request.target {
            let mentions = try await storage.docGraphUnlinkedMentions(ofDoc: id)
            payload["unlinked_count"] = mentions.count
            payload["unlinked"] = mentions.prefix(limit).map(Self.notesGraphMentionPayload)
        }
        return payload
    }

    static func blockNotFoundMessage(_ id: String, teamID: String?) -> String {
        teamID == nil
            ? "No Doc in My Library holds the block ((\(id))). For a team's Doc, pass its team_id."
            : "No Doc in that team's library holds the block ((\(id)))."
    }

    static func notesGraphPagePayload(_ group: DocGraphReferenceGroup) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": group.kind.rawValue,
            "id": group.id,
            "title": group.title,
            "updated_at": ISO8601DateFormatter().string(from: group.updatedAt),
            "blocks": group.blocks.map(notesGraphBlockPayload),
        ]
        if let day = DailyNote.dayKey(ofID: group.id), group.kind != .idea { payload["day"] = day }
        return payload
    }

    static func notesGraphBlockPayload(_ block: DocGraphBlock) -> [String: Any] {
        var payload: [String: Any] = [
            "doc_id": block.docID,
            "block_id": block.blockID.map { $0 as Any } ?? NSNull(),
            "kind": block.kind.rawValue,
            "markdown": block.markdown,
            "plain_text": block.plainText,
            "breadcrumbs": block.breadcrumbs,
            "line": block.line,
        ]
        if !block.childrenMarkdown.isEmpty { payload["children_markdown"] = block.childrenMarkdown }
        return payload
    }

    static func notesGraphMentionPayload(_ mention: DocGraphMention) -> [String: Any] {
        var payload: [String: Any] = [
            "doc_id": mention.docID,
            "doc_title": mention.docTitle,
            "revision": mention.revision,
            "block": notesGraphBlockPayload(mention.block),
            "start": mention.start,
            "end": mention.end,
        ]
        let markdown = mention.block.markdown as NSString
        if mention.start >= 0, mention.end > mention.start, mention.end <= markdown.length {
            payload["words"] = markdown.substring(with: NSRange(location: mention.start, length: mention.end - mention.start))
        }
        return payload
    }

    // MARK: get_block

    func notesGraphBlock(arguments: [String: Any]) async throws -> [String: Any] {
        let raw = (arguments["block_id"] as? String) ?? ""
        guard let id = Self.notesGraphBlockID(raw) else {
            throw MCPError.invalidInput("block_id must be a block's id: nine lowercase letters and digits, the ` ^id` a block ends with or what ((id)) names.")
        }
        let namedTeamID = (arguments["team_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamID = namedTeamID?.isEmpty == false ? namedTeamID : nil
        let storage = notebookFileStorage
        guard let block = try await storage.docGraphBlocks([id], teamID: teamID)[id] else {
            throw MCPError.notFound(Self.blockNotFoundMessage(id, teamID: teamID))
        }
        let doc = try await storage.loadArtifact(block.docID)
        let counts = try await storage.docGraphReferenceCounts(inDoc: block.docID)
        var payload = Self.notesGraphBlockPayload(block)
        payload["block_id"] = id
        payload["doc_title"] = doc.map { $0.title as Any } ?? NSNull()
        // A block nothing references is absent from the counts: none.
        payload["reference_count"] = counts[id] ?? 0
        if let day = DailyNote.dayKey(ofID: block.docID) { payload["day"] = day }
        return payload
    }

    // MARK: Daily notes

    /// The day `date` names, as `DailyNote` keys it: `YYYY-MM-DD`, a day's
    /// title as Docs write it ("October 6th, 2026"), or today, yesterday or
    /// tomorrow; today, where the Mac is, when it is left out or blank.
    static func dailyNoteDayKey(from value: Any?, now: Date = Date(), calendar: Calendar = .current) throws -> String {
        let today = DailyNote.dayKey(for: now, calendar: calendar)
        guard let value, !(value is NSNull) else { return today }
        guard let raw = value as? String else {
            throw MCPError.invalidInput("date must be a day written YYYY-MM-DD, such as \"\(today)\".")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text.lowercased() {
        case "", "today":
            return today
        case "yesterday", "tomorrow":
            guard let day = calendar.date(byAdding: .day, value: text.lowercased() == "yesterday" ? -1 : 1, to: now) else {
                throw MCPError.invalidInput("date \(text) could not be worked out on this Mac's calendar.")
            }
            return DailyNote.dayKey(for: day, calendar: calendar)
        default:
            break
        }
        if DailyNote.date(forDayKey: text, calendar: calendar) != nil { return text }
        if let key = DailyNote.dayKey(fromTitle: text, calendar: calendar) { return key }
        throw MCPError.invalidInput("date must be a real day written YYYY-MM-DD, such as \"\(today)\"; \(text) is not one.")
    }

    func dailyNote(arguments: [String: Any]) async throws -> [String: Any] {
        let dayKey = try Self.dailyNoteDayKey(from: arguments["date"])
        let create = arguments["create"] as? Bool ?? false
        let id = DailyNote.id(forDayKey: dayKey)
        guard let title = DailyNote.title(forDayKey: dayKey) else {
            throw MCPError.invalidInput("\(dayKey) is not a day this Mac's calendar has.")
        }
        let storage = notebookFileStorage
        var created = false
        if try await storage.loadArtifact(id) == nil {
            guard create else {
                return [
                    "exists": false,
                    "day": dayKey,
                    "doc_id": id,
                    "title": title,
                    "message": "There is no daily note for \(title). Pass create: true to make it, or write in it with append_to_daily_note, which makes it.",
                ]
            }
            _ = try await storage.ensureDailyNote(dayKey: dayKey)
            created = true
        }
        let snapshot = try await storage.artifactMarkdown(id)
        return [
            "exists": true,
            "created": created,
            "day": dayKey,
            "doc_id": id,
            "title": snapshot.artifact.title,
            "markdown": snapshot.markdown,
            "revision": snapshot.revision,
            "total_characters": snapshot.markdown.count,
            "updated_at": ISO8601DateFormatter().string(from: snapshot.artifact.updatedAt),
            "guidance": "A daily note is an ordinary Doc: append_to_daily_note adds at its end, edit_doc with this revision changes it in place, and get_linked_references with its doc_id lists what links the day.",
        ]
    }

    func appendToDailyNote(arguments: [String: Any]) async throws -> [String: Any] {
        guard let markdown = arguments["markdown"] as? String,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidInput("markdown is required: the text to add to the day's note.")
        }
        let dayKey = try Self.dailyNoteDayKey(from: arguments["date"])
        let id = DailyNote.id(forDayKey: dayKey)
        let storage = notebookFileStorage
        // A picture line a ForeverLM image tool gave is kept as the note's own
        // picture, as write_doc and edit_doc keep one; one this Mac cannot
        // draw refuses the write before anything is made.
        let rendering = await storage.renderDocPictures(in: markdown)
        guard rendering.failures.isEmpty else {
            let lines = rendering.failures.map { "- \($0.address): \($0.reason)." }.joined(separator: "\n")
            throw MCPError.invalidInput(
                "Nothing was added. A Doc keeps its own copy of every picture it shows, and \(rendering.failures.count == 1 ? "this picture" : "these pictures") could not be drawn on the learner's Mac:\n\(lines)\nUse each picture line exactly as show_source_image, inspect_paper_figure, generate_image or list_images returned it, or leave the line out."
            )
        }
        let existed = try await storage.loadArtifact(id) != nil
        let note = try await storage.ensureDailyNote(dayKey: dayKey)
        let addition = try await storage.keepDocPictures(rendering.pictures, in: markdown, artifactID: note.id)
        // Read, add, write with the revision read: the learner may be typing
        // in the note, and a write over a newer body would drop their line.
        // A newer body is read again and the addition goes after it.
        for _ in 0..<3 {
            let current = try await storage.artifactMarkdown(note.id)
            let body = Self.dailyNoteAppending(addition.markdown, to: current.markdown)
            do {
                let saved = try await storage.writeArtifactMarkdownAndSync(
                    artifactID: note.id,
                    markdown: body,
                    expectedRevision: current.revision,
                    versionReason: .assistantEdit
                )
                var payload: [String: Any] = [
                    "doc_id": note.id,
                    "day": dayKey,
                    "title": saved.artifact.title,
                    "revision": saved.revision,
                    "created": !existed,
                    "total_characters": saved.markdown.count,
                    "message": "Added to \(saved.artifact.title).",
                ]
                if addition.kept > 0 { payload["pictures_kept"] = addition.kept }
                return payload
            } catch ArtifactError.conflict {
                continue
            }
        }
        throw MCPError.invalidInput("Nothing was added. The daily note kept changing while this was being saved — the learner may be writing in it right now. Try again in a moment.")
    }

    // MARK: Plans

    /// The quarter or week `get_plan` asks for: a day in it (`YYYY-MM-DD`),
    /// its key or its title, or this, next or last; the present one when
    /// `value` is left out or blank.
    static func planPeriod(scale: PlanScale, from value: Any?, now: Date = Date(), zone: TimeZone = .current) throws -> PlanPeriod {
        let present = PlanPeriod.containing(now, scale: scale, zone: zone)
        guard let value, !(value is NSNull) else { return present }
        guard let raw = value as? String else {
            throw MCPError.invalidInput("date must be text: a day as YYYY-MM-DD, or \(present.key).")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let named: PlanPeriod?
        switch text.lowercased() {
        case "", "this", "now", "current", "today":
            return present
        case "next":
            named = present.offset(by: 1, zone: zone)
        case "last", "previous":
            named = present.offset(by: -1, zone: zone)
        default:
            let calendar = PlanPeriod.gregorian(zone)
            if let day = DailyNote.date(forDayKey: text, calendar: calendar) {
                named = PlanPeriod.containing(day, scale: scale, zone: zone)
            } else {
                named = PlanPeriod(key: text) ?? PlanPeriod(title: text, zone: zone)
            }
        }
        guard let period = named else {
            throw MCPError.invalidInput("date must be a day in the \(scale.rawValue) as YYYY-MM-DD, its key such as \(present.key), its title such as \(present.title(zone: zone)), or this, next or last; \(text) is none of these.")
        }
        guard period.scale == scale else {
            throw MCPError.invalidInput("\(text) names a \(period.scale.rawValue), and scale asks for a \(scale.rawValue). Pass scale \(period.scale.rawValue), or a day in the \(scale.rawValue) you mean.")
        }
        return period
    }

    func plan(arguments: [String: Any]) async throws -> [String: Any] {
        guard let rawScale = (arguments["scale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let scale = PlanScale(rawValue: rawScale) else {
            throw MCPError.invalidInput("scale is required: quarter or week. A day is planned into the Mac's Calendar (get_calendar_events, create_calendar_event).")
        }
        let period = try Self.planPeriod(scale: scale, from: arguments["date"])
        let create = arguments["create"] as? Bool ?? false
        let storage = notebookFileStorage
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        var payload: [String: Any] = [
            "scale": scale.rawValue,
            "key": period.key,
            "doc_id": period.id,
            "title": period.title(),
        ]
        if let start = period.start(), let end = period.end(),
           let last = PlanPeriod.gregorian().date(byAdding: .day, value: -1, to: end) {
            payload["starts"] = day.string(from: start)
            payload["ends"] = day.string(from: last)
        }
        var created = false
        if try await storage.loadArtifact(period.id) == nil {
            if create {
                _ = try await storage.ensurePlan(period)
                created = true
            } else {
                payload["exists"] = false
                payload["message"] = "There is no plan for \(period.title()) yet. Pass create: true to make it from its template."
            }
        }
        if created || payload["exists"] == nil {
            let snapshot = try await storage.artifactMarkdown(period.id)
            payload["exists"] = true
            payload["created"] = created
            payload["title"] = snapshot.artifact.title
            payload["markdown"] = snapshot.markdown
            payload["revision"] = snapshot.revision
            payload["updated_at"] = ISO8601DateFormatter().string(from: snapshot.artifact.updatedAt)
        }
        switch period {
        case .week:
            if let quarter = period.quarter() {
                var above: [String: Any] = ["key": quarter.key, "doc_id": quarter.id, "title": quarter.title()]
                if try await storage.loadArtifact(quarter.id) != nil {
                    above["exists"] = true
                    above["markdown"] = try await storage.artifactMarkdown(quarter.id).markdown
                } else {
                    above["exists"] = false
                }
                payload["quarter"] = above
            }
        case .quarter:
            var weeks: [[String: Any]] = []
            for week in period.weeks() {
                weeks.append([
                    "key": week.key,
                    "doc_id": week.id,
                    "title": week.title(),
                    "planned": try await storage.loadArtifact(week.id) != nil,
                ])
            }
            payload["weeks"] = weeks
        }
        payload["guidance"] = "A plan is an ordinary Doc: edit_doc with its revision writes in it (keep its headings), and get_linked_references with its doc_id lists what links it. A week's plan reads its quarter's; a day is planned into the Calendar with the week's plan in view."
        return payload
    }

    /// `existing` with `addition` after it as its own block or blocks: a
    /// bullet that follows a bullet of the same kind joins that list, as the
    /// next bullet of an outline; anything else starts after a blank line, so
    /// a paragraph does not run into the one before it. Blank lines around
    /// the addition are dropped, and the result ends with one newline.
    /// Nothing in `existing` changes but the whitespace at its very end.
    static func dailyNoteAppending(_ addition: String, to existing: String) -> String {
        let added = trimmedMarkdownBlock(addition)
        guard !added.isEmpty else { return existing }
        var body = existing
        while let last = body.last, last.isWhitespace { body.removeLast() }
        guard !body.isEmpty else { return added + "\n" }
        let joinsList = trailingListMarker(of: body).map { $0 == leadingListMarker(of: added) } ?? false
        return body + (joinsList ? "\n" : "\n\n") + added + "\n"
    }

    /// Markdown without the blank lines before and after it.
    private static func trimmedMarkdownBlock(_ markdown: String) -> String {
        var lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var text = lines.joined(separator: "\n")
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    /// The marker of the list `markdown` ends in — `-`, `*`, `+`, or `1.` /
    /// `1)` for an ordered one — or nil when it ends in anything else. Read
    /// from its last run of lines without a blank one: the nearest line that
    /// starts at the margin decides, so nested bullets and a bullet's
    /// indented lines belong to the list above them.
    static func trailingListMarker(of markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        var index = lines.count - 1
        while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index -= 1 }
        while index >= 0, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            let line = lines[index]
            if let first = line.first, first != " ", first != "\t" {
                return listMarker(of: line)
            }
            index -= 1
        }
        return nil
    }

    /// The list marker the first line of `markdown` starts with at the
    /// margin, or nil.
    static func leadingListMarker(of markdown: String) -> String? {
        guard let first = markdown.components(separatedBy: "\n").first,
              let character = first.first, character != " ", character != "\t" else { return nil }
        return listMarker(of: first)
    }

    /// `-`, `*` or `+` for a bullet, `1.` or `1)` for a numbered item; nil
    /// for any other line, a thematic break (`---`, `* * *`) included.
    static func listMarker(of line: String) -> String? {
        if line.range(of: #"^(?:[-*_][ \t]*){3,}$"#, options: .regularExpression) != nil { return nil }
        if let range = line.range(of: #"^[-*+](?=[ \t]|$)"#, options: .regularExpression) {
            return String(line[range])
        }
        if let range = line.range(of: #"^[0-9]{1,9}[.)](?=[ \t]|$)"#, options: .regularExpression),
           let delimiter = line[range].last {
            return "1" + String(delimiter)
        }
        return nil
    }

    // MARK: read_doc's resolve_references

    /// What `read_doc` says when it returned a Doc's references resolved.
    static func noteResolvedReferences(_ payload: inout [String: Any]) {
        payload["references_resolved"] = true
        payload["references_note"] = "markdown has the notes graph resolved, for reading: block references and embeds read as the blocks' words, [[Title]] and #tag links as their words, and block id markers are gone. To edit, call read_doc without resolve_references and quote find text from that; revision is the stored Doc's."
    }
}
#endif
