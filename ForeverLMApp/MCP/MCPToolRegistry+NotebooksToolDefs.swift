// MCPToolRegistry: the notebooks tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var notebooksToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_app_context",
                description: "Get what is open in the ForeverLM app: the Notebook each open window holds, frontmost window first and marked, with its title, notebook_id and source count (a window outside any Notebook says so), then the sources the frontmost window's Notebook reads. What a window holds is discoverable context, never an implicit MCP default. Call this only when the learner explicitly asks about the Notebook or sources open in ForeverLM; otherwise use list_sources or resolve an explicitly named Notebook with list_notebooks.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "list_notebooks",
                description: "List ForeverLM Notebooks. A Notebook is an open-ended source pool and MCP context; timebound outcomes inside it are listed separately with list_goals.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_completed": ["type": "boolean", "description": "Include Notebooks explicitly marked done or archived. Defaults to false."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_notebook",
                description: "Create a new Notebook (an open-ended research effort over a source pool). Called from inside a ForeverLM chat, it turns that chat into a Notebook: the chat moves into it with the sources it discussed and the Pages it wrote, and the window opens the Notebook. So when the learner asks to turn this chat into a Notebook (make it one, move it into one), call this once, without title or source_ids, and never write a Page in its place. Seed it with source_ids; set discover=true to auto-suggest related sources by topic. A deadline belongs on a timebound Goal created with create_learning_goal and optionally tagged to this Notebook. Check list_notebooks first and reuse an existing Notebook when one fits; creating with a title that matches an existing Notebook fails unless allow_duplicate=true. Omit title, as the app's New notebook does, and the Notebook is \"New notebook\" until ForeverLM names it, title and card description, from its sources and its first chat; a title or summary given here or with update_notebook is never renamed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Notebook title. Omit it to let ForeverLM name the Notebook from its sources and chats."],
                        "instructions": ["type": "string", "description": "The learner's standing instructions for this Notebook — guidance to follow in every chat that works in it (the app's Instructions field). Guidance for the model, not display copy."],
                        "summary": ["type": "string", "description": "A short description shown under the title on the Notebook's card (the app's Description field): one line of display copy for the learner, not guidance for the model."],
                        "topic": ["type": "string", "description": "Natural-language topic for discovery. Defaults to the title."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs to seed the Notebook (added as approved)."],
                        "daily_target": ["type": "integer", "description": "Items per daily quiz. Defaults to 3."],
                        "discover": ["type": "boolean", "description": "Auto-discover related sources by topic. Defaults to false."],
                        "research_questions": ["type": "array", "items": ["type": "string"], "description": "The Notebook's defining research questions, in priority order — what the Notebook exists to answer (distinct from emergent open questions)."],
                        "repository": ["type": "string", "description": "The GitHub repository this Notebook is about, as owner/repo (owner/repo.git and github.com URLs are accepted). Only the name is stored; chats read the repository live through the GitHub tools (read_github_file, search_github_code, list_github_issues, …) and nothing from it enters the library."],
                        "allow_duplicate": ["type": "boolean", "description": "Pass true to create a second Notebook with an existing title. Defaults to false, which rejects collisions."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "update_notebook",
                description: "Update an explicitly identified Notebook's settings or archive/restore it. Omitted fields keep their current value; pass instructions \"\" to clear them, or repository \"\" to unlink the GitHub repository. Archiving hides the Notebook from normal lists without deleting its sources, Goals, chats, notes, or review history.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "title": ["type": "string", "description": "New notebook title."],
                        "instructions": ["type": "string", "description": "The learner's standing instructions for this Notebook — guidance to follow in every chat that works in it (the app's Instructions field). Pass \"\" to clear."],
                        "summary": ["type": "string", "description": "A short description shown under the title on the Notebook's card (the app's Description field): one line of display copy, not guidance for the model. Pass \"\" to clear."],
                        "topic": ["type": "string", "description": "Natural-language topic for discovery. Pass \"\" to reset to the title."],
                        "daily_target": ["type": "integer", "description": "Items per daily quiz."],
                        "discover": ["type": "boolean", "description": "Enable or disable auto-discovery of related sources by topic. Enabling it, or changing the topic while enabled, runs a discovery pass."],
                        "research_questions": ["type": "array", "items": ["type": "string"], "description": "Replaces the Notebook's defining research questions wholesale, in priority order. Pass [] to clear; omit to keep the current list."],
                        "related_notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Replaces the complete directional set of this Notebook's context notebooks: the related Notebooks whose sources and synthesis it can draw on. Linking alone puts nothing into its chats: the learner puts a context notebook in with its box in the Sources column, or set_notebook_source_selection does with context_notebook_ids. A Notebook unlinked leaves its chats too. Pass [] to clear; omit to keep current links. Use list_notebooks for IDs."],
                        "repository": ["type": "string", "description": "The GitHub repository this Notebook is about, as owner/repo (owner/repo.git and github.com URLs are accepted). Only the name is stored; chats read it live through the GitHub tools. Pass \"\" to unlink; omit to keep the current repository."],
                        "status": ["type": "string", "enum": ["active", "archived"], "description": "Set archived to hide the Notebook without deleting anything; set active to restore it."],
                        "think_first": ["type": "string", "enum": ["library", "off", "summariesAndStudio", "alsoChat"], "description": "This Notebook's own Think first level, over the library's (set_app_setting think_first.level): off; summariesAndStudio asks for the learner's own line before a source's gist, a Studio report and Find directions; alsoChat also asks for a guess before a question in the Notebook's chat. library takes the Notebook's own level away so the library's applies. It is the learner's own, never a teammate's. Ask the learner before changing it."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_notebook",
                description: "Permanently delete a Notebook: its source pool membership, planning state, open questions, and notes. Any Goals nested in the Notebook are deleted with it, and the Notebook's workspace files are moved to the Trash. Sources stay in the library. Ask separately whether chats filed in the Notebook should also be deleted; delete_chats defaults to false, which keeps them as ungrouped chats. This cannot be undone — call get_notebook first and confirm the Notebook's name and its Goal count with the user before deleting. notebook_id is required; there is no active-Notebook default.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "ID of the Notebook to delete. Use list_notebooks to find it."],
                        "delete_chats": ["type": "boolean", "description": "Delete chats filed in this Notebook too. Defaults to false, which keeps them in the ungrouped Chats list."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "get_notebook",
                description: "Get an explicitly identified Notebook with its standing instructions, key research questions, linked GitHub repository (repository, null when none), linked source metadata, its context notebooks (related_notebooks), each with in_chat: whether the learner put it into the Notebook's chats, and Think first: think_first, the Notebook's own level (null when it follows the library's), and think_first_level, the level that applies.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "add_notebook_sources",
                description: "Add existing source IDs to an explicitly identified Notebook's persistent source context. To find candidates first, call search_sources_semantic with exclude_notebook_id set to this Notebook so sources already in it never come back as results. Sources already in the Notebook are skipped.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Existing source IDs to add"],
                    ],
                    "required": ["notebook_id", "source_ids"],
                ]
            ),
            MCPToolDef(
                name: "discover_sources",
                description: "Find sources a Notebook is missing with one web search on the chat's model, using the Notebook's title, instructions, research questions and sources as context. Returns a one-sentence summary and up to count candidates, each with one line on why it fits. ForeverLM keeps an address only when the search engine cited it, Crossref knows its DOI, or the page opens (left_out counts the rest), sets aside addresses that are never sources, such as a home or search page, a Google Doc or a playlist (not_sources counts them), and reads each candidate's kind off its address. For papers, search_literature searches PubMed for free. Each candidate says whether the library already holds it (in_library, library_source_id) and whether the Notebook does (in_notebook). Nothing is imported: show the learner the list and import only the ones they pick, with import_paper_from_url for a paper (it needs its PDF; one behind a paywall lands as PDF needed) and add_sources for the rest, then add_notebook_sources with the returned ids; a candidate in_library needs only add_notebook_sources. Refused before anything is spent when the chat's model cannot search the web. An assistant that can search the web itself may do that instead and import the same way.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "query": ["type": "string", "description": "What to look for. Omit to search for the Notebook's own subject, its title."],
                        "count": ["type": "integer", "description": "How many candidates, 5 to 15 (default 10)."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Sources the search treats as the Notebook's, by ID. Defaults to the Notebook's own ticked sources."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "list_notebook_sources",
                description: "List an explicitly identified Notebook's persistent source context, including source IDs, metadata, and per-source understanding state (to-read/reading/understood, quiz scores, review-due): its own sources, then those of its context notebooks (via_context_notebook_id), with in_chat for each source a new chat in the Notebook reads, and context_notebooks saying which of them the learner put into its chats.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "reorder_notebook_sources",
                description: "Set the study order of an explicitly identified Notebook's approved sources — which ones the learner wants to do first. source_ids may be a subset: listed sources are placed first in the given order; all remaining approved sources keep their current relative order after them. The new order drives list_notebook_sources, get_notebook_context, the in-app pool, and daily quiz pacing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Approved source IDs in the desired study order (first = study first). May be a subset; unlisted sources follow in their current order."],
                    ],
                    "required": ["notebook_id", "source_ids"],
                ]
            ),
            MCPToolDef(
                name: "set_notebook_source_selection",
                description: "Choose which sources an explicitly identified Notebook's chats read — the checkboxes beside its sources in ForeverLM — and which of its context notebooks (the Notebooks in related_notebook_ids) they read too. Its own sources are ticked by default; a context notebook's sources reach its chats only once put in (context_notebook_ids), and taking it out keeps it linked. mode include ticks source_ids and puts context_notebook_ids in, as its box does: one that was out comes in with any of its sources the learner unticked still unticked, and one already in has every source of it ticked (ticking a source of a context notebook not in its chats puts that notebook in with that source alone); exclude unticks source_ids and takes context_notebook_ids out; only makes the chats read exactly source_ids and the context_notebook_ids; all ticks every source the chats draw on and none unticks them, leaving context notebooks in or out as they are. The choice is the learner's own (it follows their account, never a team's copy) and changes no Notebook membership or link: an unticked source stays where it is and any chat can still read it on request. New chats in the Notebook start with the ticked sources, and so does a chat not yet sent; a chat already under way keeps its own. What the Studio makes reads only the Notebook's own ticked sources. list_notebook_sources reports in_chat for each source and context_notebooks.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "mode": ["type": "string", "enum": ["include", "exclude", "only", "all", "none"], "description": "How to change the ticks."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs from list_notebook_sources: the Notebook's own or its context notebooks'. include, exclude and only take source_ids, context_notebook_ids or both."],
                        "context_notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Context notebook IDs (list_notebook_sources context_notebooks, or related_notebook_ids) to put into the Notebook's chats (include, only) or take out (exclude)."],
                    ],
                    "required": ["notebook_id", "mode"],
                ]
            ),
            MCPToolDef(
                name: "list_notebook_collections",
                description: "List the learner's collections of Notebooks: the Collections ForeverLM groups its Notebooks by (the Space's Group by Collection, the iPhone's Home). Each collection has an id, a name (a leading emoji is its icon) and the notebook_ids of the Notebooks in it, by title. A Notebook can be in any number of collections, or none. Collections are the learner's own grouping: they change nothing about a Notebook, follow the learner's account to their other devices, and a team's Notebook is in the collections of each member who put it there. update_notebook_collection changes them.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "update_notebook_collection",
                description: "Change the learner's collections of Notebooks, the Collections ForeverLM groups its Notebooks by (list_notebook_collections lists them). action create makes a collection called name, with notebook_ids in it when given, and answers its id; rename gives collection_id the name; delete deletes collection_id, and the Notebooks in it stay as they are; add_notebooks and remove_notebooks put notebook_ids in collection_id or take them out. A collection changes nothing about a Notebook, and the change follows the learner's account to their other devices.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["create", "rename", "delete", "add_notebooks", "remove_notebooks"], "description": "What to change."],
                        "collection_id": ["type": "string", "description": "Collection ID from list_notebook_collections. Required for rename, delete, add_notebooks and remove_notebooks."],
                        "name": ["type": "string", "description": "The collection's name, for create and rename. A leading emoji is its icon."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Notebook IDs from list_notebooks: the Notebooks to put in (create, add_notebooks) or take out (remove_notebooks)."],
                    ],
                    "required": ["action"],
                ]
            ),
            MCPToolDef(
                name: "get_notebook_context",
                description: "Read an explicitly identified Notebook's full research context for an external assistant, as its chats read it: Notebook-native workspace files, the library sources its chats read (its own ticked sources and those of the context notebooks the learner put into its chats, with those notebooks' instructions, notes and materials), synthesis notes, open questions, per-source understanding state, recent review summaries, and source content excerpts. It says what it leaves out (unticked sources, context notebooks out of its chats); list_notebook_sources lists them. When the Notebook is linked to a GitHub repository the context names it; read the repository itself live with the GitHub tools.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "max_source_chars": ["type": "integer", "description": "Maximum characters per source content excerpt. Defaults to 8000."],
                        "include_emergent_state": ["type": "boolean", "description": "Include synthesis notes, open questions, understanding state, and recent reviews before source content. Defaults to true."],
                        "include_source_content": ["type": "boolean", "description": "Include hydrated source text excerpts. Defaults to true. Set false for a lightweight state-only snapshot."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "list_notebook_files",
                description: "List an explicitly identified Notebook's workspace files. Returns stable relative paths and identifies Markdown files that can be read or edited with the Notebook Markdown tools.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "list_teams",
                description: "List every team this account owns or has joined: id, name, this account's role (owner or member) and permission (readWrite or readOnly), the roster with each member's user_record_name and display name (is_current_user marks this account), and the invitation share_url when iCloud has minted one. A team is a library of its own in the owner's iCloud; call this before share_with_team or before assigning a task so names resolve to ids.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "create_team",
                description: "Create a team this account owns: a shared library in this account's iCloud. Returns the team. Members are invited from ForeverLM through Apple's sharing sheet, not through MCP; content is put into the team with share_with_team. Check list_teams first and reuse a team that already fits.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "The team's name, shown to every member and on the invitation."],
                    ],
                    "required": ["name"],
                ]
            ),
            MCPToolDef(
                name: "share_with_team",
                description: "Copy sources, Notebooks, Docs, chats or courses into a team. Sharing copies: each item gets a team-scoped copy in the team's library and the original stays exactly where it is, so nothing leaves My Library. Two members sharing the same paper produce one team copy, and sharing an item again updates its copy. A Notebook travels with its instructions, research questions and nested Goals, and by default with its sources, Docs and chats; from then on whatever is filed under the Notebook later (a source, a Goal, a Doc, a chat and its later turns) follows it into the team. A chat shares as a read-only transcript with the learner's scores, ratings and reading context stripped. A course shares with its lectures, readings, quizzes and every source on its path (copied into the team, files included), so each member takes it with their own watched lectures, completed quiz sittings, scores and gate; the learner's own progress stays behind, and sharing it again brings the team's copy up to date. A Doc, site or animation travels with its sources: the sources its record links (an animation's sources, a site's source_ids) are copied into the team and the team copy names the team's copies, and the web sources its body cites that only My Library holds (papers and books, or anything with a file here) come along unless include_cited_sources is false; the result lists them under linked_sources_shared, cited_sources_shared and sources_not_shared. Every kind but chat gives the team's members copies of sources, so the learner affirms once, in ForeverLM or through share_notebook or here, that they may share them; until they have, this is refused with the question to ask: \"Do you have the rights to share these sources with the people you invite, in line with copyright and each source's terms?\" Pass rights_affirmed_by_learner: true only after asking the learner exactly that and hearing yes; their answer is recorded and not asked again. A chat's transcript carries no source and asks nothing. Refused when the team is read-only for this account. Returns the team copy id for every original. To share a notebook with people in one step, team made and invitation link included, use share_notebook.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "Team ID from list_teams."],
                        "kind": ["type": "string", "enum": ["source", "notebook", "doc", "chat", "course"], "description": "What the ids name."],
                        "ids": ["type": "array", "items": ["type": "string"], "description": "IDs of the items to share: source IDs, Notebook IDs from list_notebooks, Doc IDs from list_docs, chat IDs from get_review_sessions, or course IDs from list_courses."],
                        "include_sources": ["type": "boolean", "description": "kind notebook only: copy the Notebook's sources into the team too. Defaults to true."],
                        "include_docs": ["type": "boolean", "description": "kind notebook only: copy the Notebook's Docs into the team too. Defaults to true."],
                        "include_chats": ["type": "boolean", "description": "kind notebook only: copy the Notebook's chats into the team as read-only transcripts too. Defaults to true."],
                        "include_cited_sources": ["type": "boolean", "description": "kind doc only. Defaults to true: the web sources the Doc cites that My Library holds and the team does not — papers and books, or anything with a file here — travel with it, so teammates can open them from the Doc's cards; the result lists them under cited_sources_shared. Pass false to keep them behind. The sources the record itself links always travel (linked_sources_shared), because the team copy names them by the team's ids."],
                        "rights_affirmed_by_learner": ["type": "boolean", "description": "true only after the learner, asked whether they have the rights to share these sources with the people they invite, in line with copyright and each source's terms, said yes. Needed while the learner has not yet affirmed; ignored once they have, and for kind chat."],
                    ],
                    "required": ["team_id", "kind", "ids"],
                ]
            ),
            MCPToolDef(
                name: "share_notebook",
                description: "Share a notebook with other people in one call, as its Share… in ForeverLM does. Without team_id: a Notebook already in one team uses that team, and a Notebook in no team gets a new team named after it (its title, emoji included). The team receives a copy of the Notebook with all its approved sources and their files, its Goals, Docs and chats, and from then on whatever is filed under the Notebook follows it into the team; the original stays in My Library. A Notebook two teams hold needs team_id. With team_id, the Notebook is shared into that team, or, when that team already has it, that team is used as it stands. Returns the team, whether it was made now, how many sources its notebook holds, the team's notebook (team_notebook_id), its members and invitations, and invitation_link: the link the team's Copy Invitation Link copies, which opens the team to anyone who has the link, with editing, when this account owns the team (link_opens_to_anyone is then true; a member's link is returned as it stands and it is false). Hand the link to the learner, saying so when it opens the team to anyone; null when iCloud has not shared the team yet, and message says why. Sharing gives the people invited copies of the notebook's sources, so the learner affirms once, in ForeverLM or here, that they may share them; until they have, this is refused with the question to ask: \"Do you have the rights to share these sources with the people you invite, in line with copyright and each source's terms?\" Pass rights_affirmed_by_learner: true only after asking the learner exactly that and hearing yes; their answer is recorded and not asked again. Refused when this account can only read the team, naming its owner to ask. Inviting named people is Apple's sharing sheet, in ForeverLM.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "The notebook's Notebook ID from list_notebooks."],
                        "rights_affirmed_by_learner": ["type": "boolean", "description": "true only after the learner, asked whether they have the rights to share these sources with the people they invite, in line with copyright and each source's terms, said yes. Needed while the learner has not yet affirmed; ignored once they have."],
                        "team_id": ["type": "string", "description": "Share into this existing team (list_teams) instead of the team that holds the Notebook or a new one named after it."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "list_notebook_tasks",
                description: "List a Notebook's tasks with every field: status (todo, doing, done), notes, due date, assignee, and the source or Doc a task is about. With no notebook_id it lists the learner's Board (Space > Board): use that to find a card on \"my board\" or \"my to-do list\" before update_notebook_task. When the Notebook is a team's, the response also carries the team and its roster so a member's name can be resolved to the user_record_name an assignee carries. A personal Notebook's tasks have no assignee.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks. Leave it out for the learner's Board."],
                        "status": ["type": "string", "enum": ["todo", "doing", "done"], "description": "Only tasks in this status."],
                        "assignee": ["type": "string", "description": "Only tasks assigned to this member: a user_record_name from the team roster, or \"me\" for this account. Team Notebooks only."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_notebook_task",
                description: "Add a to-do. With no notebook_id it goes on the learner's Board (Space > Board, columns To do, In progress, Done): use that for \"add this to my board\", \"put it on my to-do list\". With a notebook_id it goes on that Notebook's tasks. In a team Notebook the task is the team's and can be assigned to a member by user_record_name (or \"me\"); every member sees it. In a personal Notebook it is the learner's own and takes no assignee. Refused when the Notebook's team is read-only for this account.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks. Leave it out for the learner's Board."],
                        "title": ["type": "string", "description": "What is to be done."],
                        "notes": ["type": "string", "description": "Optional detail."],
                        "status": ["type": "string", "enum": ["todo", "doing", "done"], "description": "Defaults to todo."],
                        "assignee_record_name": ["type": "string", "description": "Team Notebooks only: a member's user_record_name from list_teams or list_notebook_tasks, or \"me\" for this account."],
                        "due_date": ["type": "string", "description": "Optional due date, YYYY-MM-DD."],
                        "source_id": ["type": "string", "description": "Optional source the task is about."],
                        "doc_id": ["type": "string", "description": "Optional Doc the task is about."],
                    ],
                    "required": ["title"],
                ]
            ),
            MCPToolDef(
                name: "update_notebook_task",
                description: "Change a task. Omitted fields keep their value. Pass assignee_record_name \"\" to unassign and due_date \"\" to clear the due date. Setting status to done stamps the completion; moving it back clears it. Refused when the Notebook's team is read-only for this account.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string", "description": "Task ID from list_notebook_tasks."],
                        "title": ["type": "string", "description": "New title."],
                        "notes": ["type": "string", "description": "New notes; pass \"\" to clear."],
                        "status": ["type": "string", "enum": ["todo", "doing", "done"]],
                        "assignee_record_name": ["type": "string", "description": "A member's user_record_name, \"me\", or \"\" to unassign. Team Notebooks only."],
                        "due_date": ["type": "string", "description": "YYYY-MM-DD, or \"\" to clear."],
                        "source_id": ["type": "string", "description": "Source the task is about; pass \"\" to clear."],
                        "doc_id": ["type": "string", "description": "Doc the task is about; pass \"\" to clear."],
                    ],
                    "required": ["task_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_notebook_task",
                description: "Delete a task from its Notebook's board. In a team Notebook every member loses it. Not undoable; confirm the title with the learner first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string", "description": "Task ID from list_notebook_tasks."],
                    ],
                    "required": ["task_id"],
                ]
            ),
            MCPToolDef(
                name: "assign_to_member",
                description: "Assign something to learn to one member of a team — a parent assigning to a child, in a family team. Each source or Doc is copied into the team (the original stays in this library) and becomes a task on the team's Assignments board for that member, pointing at the team's copy. The task marks itself done when the member reads the source to the end or reviews it. Assigning the same item to the same member again updates their open task. Refused in a read-only team.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "Team ID from list_teams."],
                        "member": ["type": "string", "description": "The member's user_record_name from list_teams, or their display name when it is unique in the team."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Sources to assign, from list_sources or search_sources_semantic."],
                        "doc_id": ["type": "string", "description": "A Doc to assign, from list_docs."],
                        "due_date": ["type": "string", "description": "Optional due date, YYYY-MM-DD."],
                        "notes": ["type": "string", "description": "Optional note for the member, such as what to look out for."],
                    ],
                    "required": ["team_id", "member"],
                ]
            ),
            MCPToolDef(
                name: "list_assignments",
                description: "With mine true (the default when no team_id is given): what other members assigned to this account, in every team, open ones first by due date, with the team and the title of the source or Doc. With a team_id: that team's Assignments board, every member's assignments with status and completion, which is how a parent sees what a child has done.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "A team's Assignments board, from list_teams."],
                        "mine": ["type": "boolean", "description": "Only what is assigned to this account."],
                        "include_done": ["type": "boolean", "description": "Include finished assignments. Defaults to false."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "get_calendar_events",
                description: "Read the learner's day from the Mac's Calendar — the day and the week are the calendar, planned onto it and moved around as they go; the quarter they serve is a plan Page that get_plan reads: every event on the calendars ForeverLM shows (Plugins › Calendar; get_calendar_settings), for one day or up to 14 from date. Each event has event_id (with occurrence_date for one occurrence of a recurring event — pass both to change it), title, calendar and calendar_id, start and end on the learner's clock (HH:MM) and start_at and end_at in ISO 8601 with the offset, all_day, when (ended, now with minutes_left, or ahead), location, join_link (the Teams, Zoom or Meet link, when there is one), notes, attendees, has_other_people (a meeting: it stays at its time and only the Calendar app may change it), and editable (whether update_calendar_event and delete_calendar_event may touch it). Each day also says its weekday, where it sits against today (relative_day), the hours the learner's day runs (day_starts, day_ends; get_day_settings), and the free stretches inside those hours — free_from_now on today, free on a day ahead — which is where a plan goes. new_events_calendar is where create_calendar_event puts an event unless told otherwise. Needs the Mac's Calendar on; the error says how to turn it on. To plan a day or a week: read it (days 7 for a week), the quarter's plan with get_plan, and get_day_activity for how recent days actually went, propose a first draft of the whole day or week with one line on what you assumed, revise it with the learner as often as they like (replying with the whole revised list each time), and once they agree add each block as an event with create_calendar_event.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD, \"today\" or \"tomorrow\". Defaults to today on the learner's Mac."],
                        "days": ["type": "integer", "minimum": 1, "maximum": 14, "description": "How many days from date to read, 1 to 14. Defaults to 1."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_calendar_event",
                description: "Add an event to the Mac's Calendar — how a day is planned: each block of work, reading, review, admin or a break is an event on the learner's clock, titled in the learner's words. It lands on the calendar of the group its title or notes name (groups in get_calendar_settings: one context of the learner's work, one calendar, one colour), else on the calendar new events go to (new_events_calendar in get_calendar_events; the learner chooses it in Plugins › Calendar), unless calendar_id names another that takes events. It shows at once in the Calendar app and in ForeverLM's Now chip, and reaches the learner's phone through their calendar account. Pass date and start, and end or duration_minutes (an event past midnight takes duration_minutes); all_day true makes an all-day event on date; repeat makes it recur (daily, weekdays, or weekly on its weekday) until repeat_until, or with no end. Blocks of work are best 90–120 minutes and never under 30. Put what the hour is for in notes — the next step, and the foreverlm:// link of a source or Doc it reads — so it opens from the event. A block on one topic may also carry its notebook's [Title](foreverlm://notebook/<id>) link in its notes, so ForeverLM's Now chip opens that notebook from the block and a bout started there is filed under it. Plan into the free stretches get_calendar_events gives, and never over a meeting with other people: the calendar itself allows overlapping events, so read the day first. Returns the event with its event_id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "What the hour is for, in the learner's words."],
                        "date": ["type": "string", "description": "YYYY-MM-DD, \"today\" or \"tomorrow\". Defaults to today."],
                        "start": ["type": "string", "description": "24-hour clock time, HH:MM. Required unless all_day."],
                        "end": ["type": "string", "description": "24-hour clock time, HH:MM, after start on the same day."],
                        "duration_minutes": ["type": "integer", "description": "Length in minutes, instead of end; the way to plan past midnight."],
                        "all_day": ["type": "boolean", "description": "true makes an all-day event on date."],
                        "notes": ["type": "string", "description": "Optional detail: the next step, a foreverlm:// link to the source or Doc the hour is for."],
                        "location": ["type": "string", "description": "Optional place or call link."],
                        "url": ["type": "string", "description": "Optional link the event opens, e.g. a call link or a foreverlm:// source link."],
                        "calendar_id": ["type": "string", "description": "Optional calendar id or title from get_calendar_settings; defaults to the calendar of the group the title or notes name, else the calendar new events go to."],
                        "repeat": ["type": "string", "enum": ["daily", "weekdays", "weekly"], "description": "Optional: make it recur; weekly repeats on date's weekday."],
                        "repeat_until": ["type": "string", "description": "Optional YYYY-MM-DD: the last day it recurs on. Leave out for no end."],
                    ],
                    "required": ["title"],
                ]
            ),
            MCPToolDef(
                name: "update_calendar_event",
                description: "Move, retitle or rewrite an event in the Mac's Calendar that the learner owns alone (editable in get_calendar_events): pass event_id and what changes. date moves it to another day at the same time; start moves it and keeps its length unless end or duration_minutes is passed; end or duration_minutes alone changes its length. notes, location and url replace the field; pass \"\" to clear one. calendar_id moves it to another calendar. For one occurrence of a recurring event pass occurrence_date too; span future changes that occurrence and every one after it. An event with other people on it (has_other_people) is refused: changing it would send them an update, so the learner changes it in the Calendar app. Returns the event as the calendar now holds it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "event_id": ["type": "string", "description": "From get_calendar_events."],
                        "occurrence_date": ["type": "string", "description": "For one occurrence of a recurring event: its occurrence_date from get_calendar_events."],
                        "title": ["type": "string"],
                        "date": ["type": "string", "description": "YYYY-MM-DD, \"today\" or \"tomorrow\": the day to move it to."],
                        "start": ["type": "string", "description": "HH:MM."],
                        "end": ["type": "string", "description": "HH:MM, after start."],
                        "duration_minutes": ["type": "integer", "description": "New length in minutes, instead of end."],
                        "all_day": ["type": "boolean"],
                        "notes": ["type": "string", "description": "Replaces the notes; \"\" clears them."],
                        "location": ["type": "string", "description": "Replaces the location; \"\" clears it."],
                        "url": ["type": "string", "description": "Replaces the link; \"\" clears it."],
                        "calendar_id": ["type": "string", "description": "Move it to this calendar (id or title)."],
                        "span": ["type": "string", "enum": ["this", "future"], "description": "For a recurring event: this occurrence (the default) or this and every later one."],
                    ],
                    "required": ["event_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_calendar_event",
                description: "Remove an event from the Mac's Calendar that the learner owns alone (editable in get_calendar_events). For one occurrence of a recurring event pass occurrence_date; span future removes it and every occurrence after it. Not undoable from here: delete only an event the learner asked you to remove or one you added for them in this conversation, and confirm first otherwise. An event with other people on it is refused; the learner declines or cancels it in the Calendar app.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "event_id": ["type": "string", "description": "From get_calendar_events."],
                        "occurrence_date": ["type": "string", "description": "For one occurrence of a recurring event: its occurrence_date from get_calendar_events."],
                        "span": ["type": "string", "enum": ["this", "future"], "description": "For a recurring event: this occurrence (the default) or this and every later one."],
                    ],
                    "required": ["event_id"],
                ]
            ),
            MCPToolDef(
                name: "get_day_activity",
                description: "Read one day's log — what ForeverLM saw the learner actually do, span by span: a paper read in the Reader (reading, listening, watching, with source_id), a chat had (chat, with chat_id) or a Doc written (doc, with doc_id), each with activity_id, start, end, duration_minutes and a foreverlm:// link that opens it; and time the learner drifted off a bout's or a calendar block's goal (off_track, with off_track_to, the site or app's bundle id they drifted to, and no link; only with Nudge Me Back on Track on, get_day_settings); on today a span still going is marked ongoing and runs to now. Also logged_minutes by kind, the day's learning bouts with their write-ups, and minutes_learned, with the day's weekday and relative_day. sources_engaged sums the log per source — what the learner read, listened to and watched that day, most time first, each with source_id, title, minutes, minutes_by_kind, first_seen, last_seen, a link, and highlights_made (the passages they marked in it that day, with their notes); a source marked but not seen open carries 0 minutes. Pass include_chat_transcripts=true when the learner asks what they learned, discussed, or should be quizzed on from that day: chat_transcripts then contains each distinct chat's actual conversation. What they learned is both halves — the chats and the sources_engaged reading, with the time spent on each; read a source's text with get_source_content when its marks are not enough. Do not infer the conversation from its linked sources. A deleted or unavailable chat is returned explicitly with available=false instead of being replaced by source content. The log is observation, the Activity pane's; nothing here changes it but delete_day_activity. Read it beside get_calendar_events to see what a day planned for actually went to.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD, \"today\" or \"tomorrow\". Defaults to today on the learner's Mac."],
                        "include_chat_transcripts": ["type": "boolean", "description": "Include each distinct chat's transcript. Use for a recap or quiz based on what the learner discussed that day. Defaults to false."],
                        "max_chars_per_chat": ["type": "integer", "description": "Transcript characters per chat when included. Defaults to 50000, minimum 1000, maximum 200000; a truncated chat says to call get_review_session_transcript."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "delete_day_activity",
                description: "Take one span off a day's log — the Activity pane's Delete on a sitting. The log is what ForeverLM saw the learner do (reading, a chat, a Doc); the span goes for good, and the sources stay. A sitting the Activity pane draws may be several spans; delete each. Not undoable; confirm with the learner first. activity_id comes from get_day_activity.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "activity_id": ["type": "string", "description": "From the log in get_day_activity."],
                    ],
                    "required": ["activity_id"],
                ]
            ),
            MCPToolDef(
                name: "get_learning_bout",
                description: "Read the learner's timer: the bout running now — a stretch of learning with a clock on it — and the day's finished ones with their write-ups. A bout is in one of five phases: learning (the clock is running, and it keeps running past its end until the learner stops it), writing (stopped, the write-up is owed), earned (written up, a break is waiting), resting (on that break), complete. Call this before any other bout tool.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD or \"today\". Defaults to today. The live bout is returned whatever day it started on."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "start_learning_bout",
                description: "Put a clock on a stretch of learning. Pass event_id (from get_calendar_events, with occurrence_date for one occurrence of a recurring event) to run one of the day's events, which gives the bout the event's title and what is left of its time; otherwise give a title. Only one bout runs at a time. The clock never ends the bout and never marks anything done — it is the learner who stops, and the write-up that finishes it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "event_id": ["type": "string", "description": "Optional calendar event from get_calendar_events to run. The bout takes its title and length."],
                        "occurrence_date": ["type": "string", "description": "With event_id, for one occurrence of a recurring event."],
                        "title": ["type": "string", "description": "What the bout is for, in the learner's words. Required when there is no event_id."],
                        "minutes": ["type": "integer", "description": "How long to run, 5 to 480. Defaults to what is left of the event, or 90."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook, from list_notebooks."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional sources the bout is for."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "end_learning_bout",
                description: "Stop the clock on a running bout without writing it up yet. The write-up is still owed and no break is earned until it is filed. Use this when the learner says they have stopped but is not ready to reflect; otherwise go straight to write_up_learning_bout, which stops the clock itself.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bout_id": ["type": "string", "description": "From get_learning_bout."],
                    ],
                    "required": ["bout_id"],
                ]
            ),
            MCPToolDef(
                name: "write_up_learning_bout",
                description: "File what a bout produced, which is what earns its break. Ask the learner two questions first and file their own words, never a summary you wrote for them: what did you learn, and what do you not understand yet. The second is the more valuable half — it is what the next bout is for — so ask it even when they only volunteer the first. Stops the clock if the bout is still running.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bout_id": ["type": "string", "description": "From get_learning_bout."],
                        "learned": ["type": "string", "description": "What the learner says they learned, in their words. Required."],
                        "unclear": ["type": "string", "description": "What they say they still do not understand, in their words."],
                        "break_minutes": ["type": "integer", "description": "Override the earned break, 5 to 20. Defaults to a minute of rest for every nine learned."],
                    ],
                    "required": ["bout_id", "learned"],
                ]
            ),
            MCPToolDef(
                name: "set_learning_bout_break",
                description: "Start or end the break a write-up earned. running=true starts it counting down on every one of the learner's devices; running=false ends it — and on a break that was never started, ends it as declined, which is the learner going straight back to work. A break cannot be started on a bout that has no write-up.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bout_id": ["type": "string", "description": "From get_learning_bout."],
                        "running": ["type": "boolean", "description": "true starts the break, false ends or declines it."],
                        "minutes": ["type": "integer", "description": "Optional length when starting, 5 to 20."],
                    ],
                    "required": ["bout_id", "running"],
                ]
            ),
            MCPToolDef(
                name: "abandon_learning_bout",
                description: "Let a bout go without a write-up: the learning is recorded as having happened and no break is earned. Use it only when the learner says the time went nowhere; a bout they did learn from should be written up, however briefly.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bout_id": ["type": "string", "description": "From get_learning_bout."],
                    ],
                    "required": ["bout_id"],
                ]
            ),
            MCPToolDef(
                name: "request_share",
                description: "Ask a team for a source its library lacks — the route for a paper or a book a card on a team Doc cannot add because it is not open on the web while a teammate holds it. The request lives in the team zone, so every member sees it; any editor whose own library holds the source answers it with fulfil_share_request, and their copy (file included) becomes the team's. Idempotent: a second request for the same address while one stands returns the standing request. Refused when the team already holds the source, or when the learner can only read the team. Requires the learner's Mac to be open and connected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "Team ID from list_teams."],
                        "url": ["type": "string", "description": "The source's web address as the Doc cites it: a DOI link, an arXiv page, a publisher page."],
                        "title": ["type": "string", "description": "Optional title, so the request reads well before the source arrives."],
                        "doc_id": ["type": "string", "description": "Optional Doc ID from list_docs the request was made from."],
                    ],
                    "required": ["team_id", "url"],
                ]
            ),
            MCPToolDef(
                name: "list_share_requests",
                description: "List a team's requests for sources — open ones by default — with who asked, from which Doc, and for the open ones whether this Mac can answer (can_fulfil: the team is editable here and My Library holds the source). Omit team_id for every team on this Mac. Requires the learner's Mac to be open and connected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "Team ID from list_teams; omit for every team."],
                        "status": ["type": "string", "enum": ["open", "fulfilled", "declined", "all"], "description": "Which requests; defaults to open."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "fulfil_share_request",
                description: "Answer an open request with this Mac's own copy: the source in My Library is shared into the team, file included, and the request records the team copy that answered it. Refused when My Library does not hold the source, when the request is already closed, or when the learner can only read the team. Answering gives the team's members a copy of the source, so the learner affirms once, in ForeverLM or through share_notebook, share_with_team or here, that they may share their sources; until they have, this is refused with the question to ask: \"Do you have the rights to share these sources with the people you invite, in line with copyright and each source's terms?\" Pass rights_affirmed_by_learner: true only after asking the learner exactly that and hearing yes; their answer is recorded and not asked again. Requires the learner's Mac to be open and connected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "request_id": ["type": "string", "description": "Request ID from list_share_requests."],
                        "rights_affirmed_by_learner": ["type": "boolean", "description": "true only after the learner, asked whether they have the rights to share these sources with the people they invite, in line with copyright and each source's terms, said yes. Needed while the learner has not yet affirmed; ignored once they have."],
                    ],
                    "required": ["request_id"],
                ]
            ),
            MCPToolDef(
                name: "decline_share_request",
                description: "Close an open request without sharing anything; every member sees it closed. Any editor of the team may. Requires the learner's Mac to be open and connected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "request_id": ["type": "string", "description": "Request ID from list_share_requests."],
                    ],
                    "required": ["request_id"],
                ]
            ),
        ]
    }
}
