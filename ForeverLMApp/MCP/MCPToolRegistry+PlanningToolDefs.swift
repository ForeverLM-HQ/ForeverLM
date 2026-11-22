// MCPToolRegistry: the planning tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var planningToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "list_scheduled_tasks",
                description: "List the learner's recurring scheduled tasks: instructions ForeverLM sends to itself on a cadence, each producing a new chat. Distinct from the Schedule, which places sources on study days.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_runs": ["type": "boolean", "description": "Include each task's recent run receipts. Defaults to false."],
                    ] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_scheduled_task",
                description: "Get one scheduled task with its recent runs, including the chat session each successful run produced.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string", "description": "The scheduled task's ID."],
                    ] as [String: Any],
                    "required": ["task_id"],
                ]
            ),
            MCPToolDef(
                name: "create_scheduled_task",
                description: "Create a recurring scheduled task. The instruction is ordinary chat text; when the task comes due, ForeverLM sends it in a new chat with the same tools you have, and the learner reads the result there. Times are wall-clock in the task's time zone.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short name shown in the Tasks list."],
                        "instruction": ["type": "string", "description": "The message to send when the task runs, e.g. \"Quiz me on what I read yesterday\"."],
                        "cadence": [
                            "type": "string",
                            "enum": ["once", "daily", "weekdays", "weekly", "monthly"],
                            "description": "How often it runs. Defaults to daily.",
                        ] as [String: Any],
                        "hour": ["type": "integer", "description": "Hour of day, 0-23. Defaults to 8."],
                        "minute": ["type": "integer", "description": "Minute of hour, 0-59. Defaults to 0."],
                        "weekday": ["type": "integer", "description": "Weekly cadence only: 1 = Sunday through 7 = Saturday."],
                        "day_of_month": ["type": "integer", "description": "Monthly cadence only: 1-31, clamped to each month's length."],
                        "date": ["type": "string", "description": "YYYY-MM-DD. Required for the once cadence; otherwise the first eligible day."],
                        "time_zone": ["type": "string", "description": "IANA identifier the wall-clock time is anchored to, e.g. Europe/Amsterdam. Defaults to this Mac's zone."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook the produced chats are filed under."],
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional sources attached to every run.",
                        ] as [String: Any],
                        "enabled": ["type": "boolean", "description": "Whether the task starts active. Defaults to true."],
                    ] as [String: Any],
                    "required": ["title", "instruction"],
                ]
            ),
            MCPToolDef(
                name: "update_scheduled_task",
                description: "Change a scheduled task. Omitted fields are left alone; pass clear_notebook to detach its Notebook, and a complete source_ids list to replace its attachments.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string", "description": "The scheduled task's ID."],
                        "title": ["type": "string"],
                        "instruction": ["type": "string"],
                        "cadence": [
                            "type": "string",
                            "enum": ["once", "daily", "weekdays", "weekly", "monthly"],
                        ] as [String: Any],
                        "hour": ["type": "integer"],
                        "minute": ["type": "integer"],
                        "weekday": ["type": "integer"],
                        "day_of_month": ["type": "integer"],
                        "date": ["type": "string", "description": "YYYY-MM-DD."],
                        "time_zone": ["type": "string", "description": "IANA identifier."],
                        "notebook_id": ["type": "string"],
                        "clear_notebook": ["type": "boolean", "description": "Detach the Notebook instead of setting one."],
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Replaces the attached sources entirely.",
                        ] as [String: Any],
                        "enabled": ["type": "boolean", "description": "Pause or resume the task."],
                    ] as [String: Any],
                    "required": ["task_id"],
                ]
            ),
            MCPToolDef(
                name: "run_scheduled_task_now",
                description: "Run a scheduled task immediately, in addition to its normal cadence. The run starts on an open, signed-in ForeverLM client and appears as a new chat. While the run generates on this Mac, cancel_ai_work with the returned work_id stops it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string", "description": "The scheduled task's ID."],
                    ] as [String: Any],
                    "required": ["task_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_scheduled_task",
                description: "Delete a scheduled task. Chats it already produced are kept.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string", "description": "The scheduled task's ID."],
                    ] as [String: Any],
                    "required": ["task_id"],
                ]
            ),
            MCPToolDef(
                name: "get_schedule",
                description: "Get the user's Schedule plan and automatic daily activity history, including source metadata, planned dates, reading/listening/watching/chat/review activity, completion timestamps, review status, and the Goals and Notebooks each placement serves. Use get_today_sources with date_basis=activity to load what the learner used on a particular day.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID: only the placements tagged with it. Omit for the whole Schedule."],
                        "include_completed": ["type": "boolean", "description": "Whether completed items should be included. Defaults to true."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_today_sources",
                description: "Get the full content of Schedule or automatically recorded activity sources for a day in one call. Use date_basis=planned for assigned work, activity for reading/listening/source-chat/review activity, and completed only for explicitly finished work. Defaults to today's pending planned sources. For what the learner watched, read or listened to today, pass date_basis=activity with the matching activity_kind and send no date at all: the word \"today\" is not a date here. Long sources are truncated per source; use get_source_content for one source's full text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID: only the placements tagged with it. Omit for the whole Schedule."],
                        "date": ["type": "string", "description": "Leave it out for today; never send the word \"today\". Only for another day, give that day as YYYY-MM-DD; past days work too."],
                        "date_basis": ["type": "string", "enum": ["planned", "activity", "completed"], "description": "planned filters by assigned day; activity filters by automatic reading, listening, watching, chat, or review activity; completed filters by the actual completion timestamp. Defaults to planned."],
                        "activity_kind": ["type": "string", "enum": ["reading", "listening", "watching", "chat", "review"], "description": "Optional activity-only filter. Use when the learner asks specifically what they read, listened to, watched, chatted about, or reviewed."],
                        "include_completed": ["type": "boolean", "description": "Also include sources already marked completed. Defaults to false."],
                        "max_chars_per_source": ["type": "integer", "description": "Content characters per source. Defaults to 50000, capped at 200000."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "assign_sources_to_day",
                description: "Put sources on a specific day of the Schedule. A source already on the Schedule moves there; one that is not yet on it, whether it sits in a Goal's or Notebook's pool or only in the library, is placed on that day. With goal_id (a Goal or a Notebook), every source named that is not yet that goal's joins it — pool and tag — including one already on the Schedule for another goal. Without goal_id nothing is tagged, and the Notebook open in a ForeverLM window is never inherited. This is how sources get onto the Schedule, and it does not disturb any other day. Use get_schedule first to see valid source IDs and day dates.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Library source IDs to place on the day"],
                        "date": ["type": "string", "description": "Target day in YYYY-MM-DD format"],
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID to tag the sources to and add them to its pool. Omit to place them untagged."],
                    ],
                    "required": ["source_ids", "date"],
                ]
            ),
            MCPToolDef(
                name: "unschedule_sources",
                description: "Take sources off the Schedule. With goal_id (a Goal or a Notebook) only that goal's tag comes off, and a source it shares with another goal stays scheduled for that one; without goal_id the sources leave the Schedule entirely. The sources stay in the library and their activity history is kept.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs on the Schedule"],
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID whose tag comes off. Omit to take the sources off the Schedule entirely."],
                    ],
                    "required": ["source_ids"],
                ]
            ),
            MCPToolDef(
                name: "forget_source_activity",
                description: "Take back activity ForeverLM recorded on sources that did not happen — a review marked by a chat that reviewed nothing, say. For each source it removes the automatic Schedule entry (the one ForeverLM made to hold activity no one planned) with every activity day under it and the read stamp when that day set it, and reopens any assignment the entry's completion closed; every device follows. Refused, with nothing changed, for a source placed on the Schedule by plan (unschedule_sources or set_source_completion are for those) and for one whose entry also holds activity on another day, which this would erase too. Not undoable; confirm with the learner first. get_today_sources with date_basis activity lists what a day recorded.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Sources whose recorded activity did not happen."],
                        "date": ["type": "string", "description": "The day the activity was recorded, YYYY-MM-DD. Every activity day of each source must be this one."],
                    ],
                    "required": ["source_ids", "date"],
                ]
            ),
            MCPToolDef(
                name: "clear_schedule_day",
                description: "Remove the sources assigned to a day of the Schedule. With goal_id only that Goal's or Notebook's sources on the day are untagged; without it every source on the day leaves the Schedule.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "Day to clear in YYYY-MM-DD format from get_schedule days"],
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID: only its sources on the day. Omit for every source on the day."],
                        "include_completed": ["type": "boolean", "description": "Whether completed items should also be removed. Defaults to false, matching the app clear-day behavior."],
                    ],
                    "required": ["date"],
                ]
            ),
            MCPToolDef(
                name: "mark_schedule_day_done",
                description: "Mark all pending, non-missing Schedule sources assigned to a day done. This records each source as reviewed on the completion date.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "Day to mark done in YYYY-MM-DD format from get_schedule days"],
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID: only its sources on the day. Omit for every source on the day."],
                    ],
                    "required": ["date"],
                ]
            ),
            MCPToolDef(
                name: "set_source_completion",
                description: "Mark a Schedule source done or reopen it. Marking done records the source as reviewed on the completion date; linked/completed review sessions are reported separately.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID on the Schedule"],
                        "is_completed": ["type": "boolean", "description": "true to mark done, false to reopen"],
                        "goal_id": ["type": "string", "description": "Optional Goal or Notebook ID that scopes the Schedule returned afterwards."],
                    ],
                    "required": ["source_id", "is_completed"],
                ]
            ),
            MCPToolDef(
                name: "create_learning_goal",
                description: "Create a timebound Goal — a deadline-bound objective, either learning-shaped ('learn about GDF15 this week') or outcome-shaped ('write an article about mitochondrial transplantation'). For an outcome Goal, make the title the deliverable. A Goal stands on its own; notebook_id is optional and only tags it to an existing source pool, so never invent a Notebook to hold a Goal the learner just voiced. With discover=true ForeverLM finds related sources already in the library by topic similarity and adds them as pending suggestions for approval; approve them with review_suggested_sources, then pace them across the days with assign_sources_to_day. Multiple Goals can run at once. IMPORTANT — end_date is required, but do not invent one silently. If the user hasn't named a date, help them choose: consider how much material the topic implies and how much work the deliverable needs, propose a specific date with your reasoning ('that's maybe 10 papers at 3/day, plus a few days to draft — I'd suggest the 29th'), and confirm before calling this.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Natural-language goal, e.g. 'Understand GDF15'."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook to tag the Goal to, so it draws on that Notebook's sources. Omit it — the common case — for a Goal that stands on its own."],
                        "topic": ["type": "string", "description": "Topic used to discover related sources. Defaults to the title."],
                        "end_date": ["type": "string", "description": "Required end date, YYYY-MM-DD. The plan paces the pool to finish by this date."],
                        "start_date": ["type": "string", "description": "Optional start date, YYYY-MM-DD. Leave it out to start today."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional seed source IDs to anchor discovery and the plan."],
                        "daily_target": ["type": "integer", "description": "Items per day. Defaults to 3."],
                        "discover": ["type": "boolean", "description": "Auto-discover related sources by topic each day. Defaults to true."],
                        "artifact_id": ["type": "string", "description": "Optional id of the Doc, Site or animation this Goal is for — the deliverable itself, e.g. the site behind 'Make a site of the rare mitochondrial diseases' (from list_docs, list_animations or a save_site result). Plan opens it from the Goal row. Refused when no record has the id."],
                    ],
                    "required": ["title", "end_date"],
                ]
            ),
            MCPToolDef(
                name: "list_goals",
                description: "List the learner's timebound Goals as shown in Plan: each has its deadline, quarter plan (`plan.doc_id` and `plan.title`), days remaining, approved/completed source counts, review status, and the Doc, Site or animation it is for as `artifact`. A Goal's deadline determines its quarter; there is no separate Goals list in a Space. Omit notebook_id to list every Goal, tagged to a Notebook or standing alone; pass it to scope to one Notebook. Notebooks themselves are listed with list_notebooks.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID to scope to. Omit to list every Goal, including untagged ones."],
                        "include_completed": ["type": "boolean", "description": "Include Goals explicitly marked done or archived. Overdue active Goals are always included."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "update_learning_goal",
                description: "Update a timebound Goal after creation: retarget its deadline, rename it, change its topic/description, adjust the daily target or discovery, tag it to another Notebook or untag it, link it to the Doc, Site or animation it is for (artifact_id) or unlink it, or mark it done/archived. Every field is optional — omitted fields keep their current value. Use this rather than deleting and recreating a Goal, so its sources, review history, and open questions survive. IMPORTANT — when the user sets or changes a deadline and hasn't named a date, do not guess silently: look at how many approved sources the Goal has and its daily target, propose a specific date with your reasoning ('12 sources at 3/day is ~4 days of reading, plus 3 days to draft — I'd suggest the 29th'), and confirm with the user before calling this. After changing a deadline, re-pace the remaining sources with assign_sources_to_day.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Timebound Goal ID to update."],
                        "title": ["type": "string", "description": "New title. For an outcome Goal this is the deliverable, e.g. 'Write article about mitochondrial transplantation'."],
                        "description": ["type": "string", "description": "New free-text description. Pass an empty string to clear it."],
                        "topic": ["type": "string", "description": "New natural-language topic used for source discovery."],
                        "end_date": ["type": "string", "description": "New deadline as YYYY-MM-DD. Must be in the future."],
                        "daily_target": ["type": "integer", "description": "Sources to cover per study day."],
                        "discover": ["type": "boolean", "description": "Whether to auto-discover related sources by topic."],
                        "notebook_id": ["type": "string", "description": "Notebook to tag the Goal to. Must name a top-level Notebook; pass an empty string to untag it and let the Goal stand on its own."],
                        "status": ["type": "string", "description": "Lifecycle state: 'active', 'done', or 'archived'. Mark 'done' when the deliverable is finished. A Goal past its deadline that is still 'active' is reported as overdue, not complete — only set 'done' when the work is actually finished."],
                        "artifact_id": ["type": "string", "description": "The Doc, Site or animation this Goal is for, by id (from list_docs, list_animations or a save_site result): Plan opens it from the Goal row. Pass an empty string to unlink. Refused when no record has the id."],
                    ],
                    "required": ["goal_id"],
                ]
            ),
            MCPToolDef(
                name: "reorder_goals",
                description: "Put the learner's Goals in an order — the drag of a Goal row in Plan. goal_ids may be a subset: the listed Goals are placed first in the given order, and every other open Goal follows in the order it already reads (placed Goals, then the rest by deadline), so reordering three never scrambles the rest. Pass an empty list to forget every placement and read by deadline again. The order drives Plan and list_goals. Each id must name an open timebound Goal (from list_goals); a Notebook, a finished Goal or an unknown id is refused and nothing changes. Confirm the order with the learner before calling this.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_ids": ["type": "array", "items": ["type": "string"], "description": "Timebound Goal IDs in the desired order (first = top of the list). May be a subset; unlisted Goals follow in their current order. An empty list clears every placement."],
                    ],
                    "required": ["goal_ids"],
                ]
            ),
            MCPToolDef(
                name: "delete_learning_goal",
                description: "Permanently delete one timebound Goal — the app's Delete on its row in Plan. The Goal's record, its source pool and its Schedule tags go; the sources stay in the library, and a chat started from the Goal stays in Chats with the link cleared. Refused for a Notebook (delete_notebook takes those, with their Goals). Not undoable; to put a Goal away and keep it, use update_learning_goal with status archived instead. Confirm with the learner first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Timebound Goal ID from list_goals."],
                    ],
                    "required": ["goal_id"],
                ]
            ),
            MCPToolDef(
                name: "list_ideas",
                description: "List the learner's Ideas — their own jotted-down thoughts, newest first, each with the research and explorations linked to it. An Idea is NOT a Goal: it has no deadline and nothing is scheduled from it (Goals are list_goals). Use this before create_idea so an existing thought is extended rather than duplicated, and when the learner asks what they have been thinking about.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_archived": ["type": "boolean", "description": "Include Ideas the learner put away. Defaults to true."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks: only the Ideas linked to it or to one of its Goals."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_idea",
                description: "Jot an Idea down for the learner — a thought with no deadline and no commitment, which is the whole point of it. Keep the title in the learner's own words; do not polish it into a goal statement. Put anything longer than a sentence in notes. If the learner names a date or asks for a plan, they want a Goal instead: use create_learning_goal, then link_idea with kind \"goal\" so the Idea records what it became. Check list_ideas first so a thought already written is extended with update_idea rather than doubled.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "The thought, in the learner's words. One line; it is collapsed to one and capped at 300 characters."],
                        "notes": ["type": "string", "description": "Optional: the rest of the thought, when there is more than the line."],
                        "links": [
                            "type": "array",
                            "description": "Optional: what the Idea already draws on, linked as it is created.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "kind": ["type": "string", "description": "One of: source, artifact, chat, goal, notebook."],
                                    "target_id": ["type": "string", "description": "The id of the record to link. Refused when this library holds no such record."],
                                ],
                                "required": ["kind", "target_id"],
                            ],
                        ],
                    ],
                    "required": ["title"],
                ]
            ),
            MCPToolDef(
                name: "update_idea",
                description: "Change an Idea after it was jotted down: reword it, write or clear its note, put it away or bring it back. Every field is optional and an omitted one is left alone. Rewording is the learner's call — do not rewrite their sentence unless they asked. To put an Idea away and keep it, pass status \"archived\"; deleting is delete_idea and is not undoable.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "idea_id": ["type": "string", "description": "Idea ID from list_ideas."],
                        "title": ["type": "string", "description": "New wording. Cannot be emptied."],
                        "notes": ["type": "string", "description": "The note. Pass an empty string to clear it."],
                        "status": ["type": "string", "description": "\"open\" or \"archived\"."],
                    ],
                    "required": ["idea_id"],
                ]
            ),
            MCPToolDef(
                name: "link_idea",
                description: "Link research or an exploration to an Idea — the drop of sources on its row in the Ideas tab. This is how an Idea accumulates what it draws on: the sources it came from (kind source), the chats that turned it over (chat), the Docs, Sites and animations it produced (artifact), and the Goal or Notebook it grew into (goal, notebook). Targets already linked are skipped and reported; an id this library does not hold is refused and nothing is written.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "idea_id": ["type": "string", "description": "Idea ID from list_ideas."],
                        "kind": ["type": "string", "description": "What is being linked: source (a library source, from list_sources or search_sources_semantic), artifact (a Doc, Site or animation, from list_docs or list_animations), chat (from list_review_session_links), goal or notebook (from list_goals and list_notebooks)."],
                        "target_ids": ["type": "array", "items": ["type": "string"], "description": "The ids to link, all of the given kind."],
                    ],
                    "required": ["idea_id", "kind", "target_ids"],
                ]
            ),
            MCPToolDef(
                name: "unlink_idea",
                description: "Take a link off an Idea. The record it pointed at is untouched — only the Idea stops naming it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "idea_id": ["type": "string", "description": "Idea ID from list_ideas."],
                        "kind": ["type": "string", "description": "The link's kind: source, artifact, chat, goal or notebook."],
                        "target_ids": ["type": "array", "items": ["type": "string"], "description": "The linked ids to take off."],
                    ],
                    "required": ["idea_id", "kind", "target_ids"],
                ]
            ),
            MCPToolDef(
                name: "delete_idea",
                description: "Permanently forget one Idea — the app's Delete on a row of the Ideas tab. Its links go with it; every source, Doc, chat and Goal they pointed at stays in the library. Not undoable: to put an Idea away and keep it, use update_idea with status \"archived\" instead. Confirm with the learner first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "idea_id": ["type": "string", "description": "Idea ID from list_ideas."],
                    ],
                    "required": ["idea_id"],
                ]
            ),
            MCPToolDef(
                name: "find_directions",
                description: "Start a search for research directions toward one of the learner's Goals, Notebooks or Ideas — what they could pursue next, not a summary of the field (\"find interesting methods to target rare mitochondrial diseases\", \"what could I do with this idea?\"). Returns the brief: the home and its standing instructions, the sources it holds and related ones in the library, the learner's Ideas and chats, every direction already proposed toward it with the learner's answer and reason, their recent answers elsewhere, and the steps to follow. Makes no model call and spends nothing: you do the searching (search_literature, web search, the library tools) and save what survives with propose_directions. If the learner's aim is not yet a Goal, Notebook or Idea, create it first — create_idea when it has no date, create_learning_goal when it has one — and pass its id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "home_id": ["type": "string", "description": "The Goal (list_goals), Notebook (list_notebooks) or Idea (list_ideas) the directions are toward."],
                        "focus": ["type": "string", "description": "Optional: what kind of directions the learner asked for, in their words (\"methods to target\", \"companies to talk to\", \"cheap experiments\")."],
                    ],
                    "required": ["home_id"],
                ]
            ),
            MCPToolDef(
                name: "search_literature",
                description: "Search the life-science and biomedical literature in PubMed for free, with no model call; it answers in about a second. Returns each work's title, authors, journal, year, DOI, abstract, whether it is a review or a preprint, its free full text in PubMed Central when there is one, and whether the learner's library already has it. Use it to establish what is known and to find prior art and counter-evidence; read a paper before resting a claim on it. The query takes PubMed syntax: words are ANDed, OR between synonyms in parentheses, quotes for a phrase, [tiab] to require a term in the title or abstract, [au] for an author (Mootha VK[au]), review[pt] for reviews. Several searches may run at once.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "What to search, e.g. \"mitochondrial disease\"[tiab] AND (hypoxia[tiab] OR HIF[tiab])."],
                        "from_year": ["type": "integer", "description": "Optional: earliest publication year."],
                        "to_year": ["type": "integer", "description": "Optional: latest publication year."],
                        "preprints_only": ["type": "boolean", "description": "Optional: only preprints PubMed holds (it carries some from bioRxiv and medRxiv). Defaults to false."],
                        "sort": ["type": "string", "description": "relevance (default) or newest."],
                        "limit": ["type": "integer", "description": "How many works, 1 to 25. Defaults to 10."],
                    ],
                    "required": ["query"],
                ]
            ),
            MCPToolDef(
                name: "propose_directions",
                description: "Save the directions a search kept for one Goal, Notebook or Idea, as proposals waiting for the learner's answer — they appear on its Directions list in the app. Call it once per search with the three to seven that survived, after find_directions. Every direction needs its sentence, why it is worth a look now, its angle, and at least one piece of evidence with a DOI or address; a direction missing any of them refuses the whole call and nothing is saved. One the home already has, reworded or not, is skipped and named. Never add papers to the library from here.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "home_id": ["type": "string", "description": "The Goal, Notebook or Idea from find_directions."],
                        "session_id": ["type": "string", "description": "Optional: the chat the search ran in, when it is not this ForeverLM chat."],
                        "directions": [
                            "type": "array",
                            "description": "At most ten.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string", "description": "The direction in one sentence: the specific mechanism or approach, and the specific population, system or problem it is aimed at."],
                                    "rationale": ["type": "string", "description": "Why it is worth a look now, in two to four sentences."],
                                    "angle": ["type": "string", "description": "gap, transfer, revival, enabling, connection, contrarian or other — the way of looking that produced it."],
                                    "evidence": [
                                        "type": "array",
                                        "description": "One to five papers or pages you actually opened. Never invent one.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "citation": ["type": "string", "description": "How the learner would cite it: \"Jain et al., Science 2016\"."],
                                                "title": ["type": "string", "description": "The paper's or page's title."],
                                                "doi": ["type": "string", "description": "The DOI (10.xxxx/…), when it has one. Preferred: it is what the library matches on."],
                                                "url": ["type": "string", "description": "The page's address, when there is no DOI or the page itself is the evidence."],
                                                "finding": ["type": "string", "description": "The one thing it shows for this direction, in a sentence."],
                                            ],
                                            "required": ["citation", "finding"],
                                        ],
                                    ],
                                    "objection": ["type": "string", "description": "The strongest case against it, or the prior art that cuts against it."],
                                    "next_step": ["type": "string", "description": "The cheapest experiment, analysis or reading that would tell whether it holds."],
                                ],
                                "required": ["title", "rationale", "angle", "evidence"],
                            ],
                        ],
                    ],
                    "required": ["home_id", "directions"],
                ]
            ),
            MCPToolDef(
                name: "list_directions",
                description: "List research directions with their evidence and the learner's answers: pursued first, then proposals waiting for an answer, then what was set aside with the learner's reason. Pass home_id for one Goal, Notebook or Idea; omit it for every home. Each piece of evidence says whether the library holds it now.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "home_id": ["type": "string", "description": "Optional: the Goal, Notebook or Idea."],
                        "status": ["type": "string", "description": "Optional: proposed, pursued or set_aside."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "update_direction",
                description: "Record the learner's answer to a direction — pursued or set_aside, with their reason in their own words — or change it after a deeper look: reword it, rewrite its rationale, objection or next step, add evidence. The answer is the app's Pursue or Set aside; the next search reads it first, so pass the reason whenever the learner gave one. status proposed takes an answer back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "direction_id": ["type": "string", "description": "Direction ID from list_directions or propose_directions."],
                        "status": ["type": "string", "description": "pursued, set_aside or proposed."],
                        "reason": ["type": "string", "description": "The learner's reason for the answer, in their words."],
                        "title": ["type": "string", "description": "New wording of the direction's sentence."],
                        "rationale": ["type": "string", "description": "New reason it is worth a look."],
                        "objection": ["type": "string", "description": "The strongest case against it. An empty string clears it."],
                        "next_step": ["type": "string", "description": "The cheapest test. An empty string clears it."],
                        "add_evidence": [
                            "type": "array",
                            "description": "One to five papers or pages you actually opened. Never invent one.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "citation": ["type": "string", "description": "How the learner would cite it: \"Jain et al., Science 2016\"."],
                                    "title": ["type": "string", "description": "The paper's or page's title."],
                                    "doi": ["type": "string", "description": "The DOI (10.xxxx/…), when it has one. Preferred: it is what the library matches on."],
                                    "url": ["type": "string", "description": "The page's address, when there is no DOI or the page itself is the evidence."],
                                    "finding": ["type": "string", "description": "The one thing it shows for this direction, in a sentence."],
                                ],
                                "required": ["citation", "finding"],
                            ],
                        ],
                    ],
                    "required": ["direction_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_direction",
                description: "Permanently forget one research direction — the app's Delete on it. A later search may propose it again; to keep it from coming back, set it aside with update_direction instead. Confirm with the learner first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "direction_id": ["type": "string", "description": "Direction ID from list_directions."],
                    ],
                    "required": ["direction_id"],
                ]
            ),
            MCPToolDef(
                name: "list_working_notes",
                description: "Read the working notes ForeverLM keeps about how the learner is working: short sentences, each a thread (work in progress), an interest, a preference, a fact or an outcome, kept by the learner or at their word and handed to every ForeverLM chat. Use it to see what they have been working on, or to answer what ForeverLM knows about them. With a query, the notes nearest those words come first (by the same on-device embedding the chat recalls with); without one, newest first. Answers with each note's id, kind, text and dates, whether notes are switched on, and running_log: ForeverLM's running summary of what they are working on (Right now, then the newest log lines). Both are kept in the background, never as Docs. Notes can be out of date; trust what the learner says now.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to rank by, e.g. \"Berlin conference\". Omit for newest first."],
                        "kind": ["type": "string", "enum": WorkingNoteKind.allCases.map(\.rawValue), "description": "Only notes of this kind."],
                        "limit": ["type": "integer", "description": "How many to return. Defaults to 50, at most 200."],
                    ] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "save_working_note",
                description: "Write one working note about how the learner works, when they ask you to remember something about it (\"remember I want a review after every paper\", \"note that Berlin is October 21\"). One sentence that stands on its own, naming the topic rather than saying \"it\", at most 400 characters. kind is one of: thread (work in progress), interest (a topic they keep returning to), preference (how they like to work), fact (something true about their situation), outcome (something finished or learned). A fact defaults. Do not write a note on your own initiative or a guess about the learner. A sentence that is already a note is not written twice.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The note: one sentence."],
                        "kind": ["type": "string", "enum": WorkingNoteKind.allCases.map(\.rawValue), "description": "thread, interest, preference, fact or outcome. Defaults to fact."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs the note is about, when it is about particular sources."],
                    ] as [String: Any],
                    "required": ["text"],
                ]
            ),
            MCPToolDef(
                name: "update_working_note",
                description: "Correct one working note: change its sentence, its kind or both. Pass the whole note_id from list_working_notes, or the first eight characters or more of it. Do it when the learner says a note is wrong or out of date; to remove one, use forget_working_note.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "Note ID from list_working_notes."],
                        "text": ["type": "string", "description": "The corrected sentence."],
                        "kind": ["type": "string", "enum": WorkingNoteKind.allCases.map(\.rawValue), "description": "The corrected kind."],
                    ] as [String: Any],
                    "required": ["note_id"],
                ]
            ),
            MCPToolDef(
                name: "forget_working_note",
                description: "Forget one working note: ForeverLM stops handing it to its chats, on every Mac signed in to the account. Not undoable; do it when the learner asks to forget it. Pass the whole note_id from list_working_notes, or the first eight characters or more of it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "Note ID from list_working_notes."],
                    ],
                    "required": ["note_id"],
                ]
            ),
            MCPToolDef(
                name: "get_goal",
                description: "Return one timebound Goal in full: deadline, days remaining, whether it is overdue, lifecycle status, the Notebook it is tagged to if any, the Doc, Site or animation it is for (`artifact`, null when none), its approved and pending sources, and open questions. Use get_schedule with its goal_id alongside it to see which days the Goal's sources are scheduled on.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Timebound Goal ID."],
                    ],
                    "required": ["goal_id"],
                ]
            ),
            MCPToolDef(
                name: "add_goal_sources",
                description: "Put existing library sources on a timebound Goal — the app's drop of sources onto a Goal's row in Plan. They join the Goal's approved pool at once (no discovery, no approval step), and a Goal tagged to a Notebook hands them on to that Notebook's pool too. Sources already on the Goal are skipped. Find ids with search_sources_semantic or list_sources; file new material with add_source first. A Notebook is refused — add_notebook_sources takes those. To place the sources on days, follow with assign_sources_to_day.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Timebound Goal ID from list_goals."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Existing library source IDs to put on the Goal."],
                    ],
                    "required": ["goal_id", "source_ids"],
                ]
            ),
            MCPToolDef(
                name: "daily_review",
                description: "Get today's chat-first daily review plan for a Learning Companion goal — merges open gaps, spaced-repetition due sources, deadline-paced new/review blend, and in-progress reading into one Review Chat session. Does not write to Schedule. With no goal_id, returns a menu of active goals. Pass start_session=false for a read-only briefing (plan + rationale, no session); default starts a linked review session with source content for a live chat review, then call end_review_session when done.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Companion goal ID: a Notebook from list_notebooks or a Goal from list_goals. Omit to get a menu of all active goals."],
                        "start_session": ["type": "boolean", "description": "Defaults to true: starts a linked review session and loads source content. Pass false for a read-only morning briefing."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "daily_quiz",
                description: "Get today's adaptive daily quiz for a Learning Companion goal and start a linked review session. Returns a blend of new and review sources (paced to the goal's end date, self-adjusting for missed days), source content, a summary of prior sessions, open gaps, and any pending source suggestions to approve. With no goal_id, returns a menu of active goals. Conduct the quiz one deep question at a time, then call end_review_session with the session_id, score, and any gaps you observed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Companion goal ID: a Notebook from list_notebooks or a Goal from list_goals. Omit to get a menu of all active goals."],
                        "date": ["type": "string", "description": "Optional date in YYYY-MM-DD. Leave it out for today."],
                        "start_session": ["type": "boolean", "description": "Defaults to true: starts a linked session and loads source content. Pass false for a read-only briefing — no session, no items marked served, no full content."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "memory_review",
                description: "The assistant's memory review: what is due for retrieval now, and by default a linked session to conduct it in this chat. It is not ForeverLM's own daily review, which is the card review the learner starts from Memory in the app; both move the same schedules; to run that card review here instead (today's cards in the app's order, each answered remembered or forgotten), use get_due_cards and record_card_result. `memory_items` are the memory items due now by their schedule, struggles first, never a new card (the app's card review introduces those, a day's allowance at a time); each includes a stable item_id, private rubric, learner context, and source anchors. An item with `ask` is a card the learner kept: ask that wording exactly as written and record it as the attempt's prompt. For any other item, generate a fresh question instead of reciting a flashcard. `new_items` are consumed sources awaiting their first retrieval attempt: load their content before asking, choose one source-grounded semantic target, and preserve its compact rubric plus an exact evidence excerpt for end_review_session. `items` are source-level refreshes. Ask one question at a time. Only when the learner explicitly finishes, call end_review_session with structured memory_attempts; existing item IDs are rescheduled and validated first reviews become durable memory items.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Optional Learning Companion goal ID to scope the refresh to that goal's sources. Omit to review across everything studied."],
                        "limit": ["type": "integer", "description": "Maximum sources to surface (default 5, max 25)."],
                        "start_session": ["type": "boolean", "description": "Defaults to true: starts a linked review session and loads source content. Pass false for a read-only briefing of what's due (no session started)."],
                        "operation_id": ["type": "string", "description": "Optional caller-generated idempotency key (max 200 characters) for start_session=true. Retry a lost response with the exact same request and operation_id to receive the same session instead of creating a duplicate."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "cohort_review",
                description: "Today's cohort review: everything the learner substantially read or listened to in the last ~10 days, plus older sources due again, plus one or two semantically adjacent sources deliberately drawn from a different stretch of time so you can ask a question that spans them. Each entry carries its role (spine / spacing / bridge), a compressed guide to what the source says, the learner's own highlights, and what they have previously made of it. YOU are the planner: choose 5-8 moves, ask one question at a time, compose fresh wording every time, and make at least one question span two sources from different times. Finish by calling record_understanding. When the app has already planned today's review by topic, `topics` lists them (topic_id, title, kind, idea_ids, source_ids): conduct those in order, one opening question per topic answerable from any of its sources, instead of planning your own moves.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "start_session": ["type": "boolean", "description": "Defaults to true: starts a linked review session. Pass false for a read-only briefing of what today would cover."],
                        "goal_id": ["type": "string", "description": "Optional Notebook/Goal ID to scope the cohort to that pool. Omit to draw from everything consumed."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_memory_review_settings",
                description: "Settings › Background › Memory review as JSON: budget_minutes (the daily review's length, your account), new_cards_per_day (how many new cards a day's review introduces, which also sets how many sources ForeverLM drafts cards from in the background each day, your account), auto_draft_cards (whether ForeverLM drafts cards into To Check as the learner finishes sources, within the daily background AI limit, your account), draft_nudges (whether the Cards to check corner card and the next morning's banner say drafted cards wait, your account), prepare_daily (\"Have today's review ready\": the reminder on mornings that hold cards, your account), ready_by_hour (when this Mac selects the morning's cards and the reminder fires), automatic_drafting (sources_a_day, this Mac's last_run with what it left waiting, and the sources that failed today), and what this Mac last did about the morning (last_preparation).",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "set_memory_review_settings",
                description: "Change Settings › Background › Memory review: budget_minutes, new_cards_per_day, auto_draft_cards, draft_nudges, prepare_daily, ready_by_hour — one or several. Writes through the pane's own entry points, so the reminder and the runner follow. Returns the settings as get_memory_review_settings reads them plus `changed`.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "budget_minutes": ["type": "integer", "description": "Minutes the daily memory review gets (5–120). Follows your account."],
                        "new_cards_per_day": ["type": "integer", "description": "New cards a day's review introduces (1–100; 10 by default). Also sets how many sources are drafted in the background each day: one for every four new cards, at least one. Follows your account."],
                        "auto_draft_cards": ["type": "boolean", "description": "Draft cards into To Check in the background as the learner finishes sources (Mark as Read, read to the end, listening or watching complete), within the daily background AI limit. Off by default: a source's card is the learner's to write. Follows your account."],
                        "draft_nudges": ["type": "boolean", "description": "Show the Cards to check corner card, and send the next morning's banner, while cards drafted in the background wait or finished sources have none. On by default; its Don't Ask Again turns it off. Follows your account."],
                        "prepare_daily": ["type": "boolean", "description": "Select the morning's cards at ready_by_hour and send the daily reminder on mornings that hold cards. Follows your account."],
                        "ready_by_hour": ["type": "integer", "description": "Hour (0–23, this Mac's clock) by which the morning's review should be waiting."],
                    ],
                    "required": [] as [String],
                ]
            ),
        ]
    }
}
