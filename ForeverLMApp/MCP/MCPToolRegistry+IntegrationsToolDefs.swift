// MCPToolRegistry: the integrations tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var integrationsToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "list_slack_channels",
                description: "List the Slack channels the learner has enabled for ForeverLM, with their names and the workspace each belongs to (the learner may have connected several workspaces; workspaces lists them). Call this before read_slack_channel to find a channel_id. Only enabled channels are listed; ForeverLM cannot see the rest of any workspace.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "read_slack_channel",
                description: "Read recent discussion from one enabled Slack channel live, with thread replies, posted links, posted files, and exact URL/DOI matches to sources already in ForeverLM. Slack tools are the only way into Slack: nothing from it is stored in the library, so a library search never answers a question about a channel. Use this read for what a channel has been discussing; to find a specific article, paper, PDF or message, call search_slack_messages instead of reading channels one by one. The read pages back through the window and says when it filled up (truncated, oldest_read); older threads may be listed with replies_omitted, and read_slack_thread reads any thread in full. Every posted file is listed under files with a download_url that ForeverLM fetches as the learner: pass a PDF's download_url to attach_pdf_to_paper (pdf_url) to complete a paper already in the library, or to import_paper_from_url (url, with source_url set to the file's permalink) to add a new one; never ask the learner to download it. IMPORTANT: every item in library_matches is already in the ForeverLM library—not merely an external link or Slack attachment. When the learner asks to read or discuss a match, you must call get_source_content with its source_id before answering. For a named reading without an exact link match, call search_sources_semantic with its DOI or title before concluding it is absent from the library. ForeverLM reads as the learner and never posts, replies, or reacts.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "channel_id": ["type": "string", "description": "Channel ID from list_slack_channels."],
                        "since_days": ["type": "integer", "description": "How many days back to read. Defaults to 7; any window up to ten years is accepted, and the result says if it was cut short."],
                    ],
                    "required": ["channel_id"],
                ]
            ),
            MCPToolDef(
                name: "read_slack_thread",
                description: "Read one Slack thread in full — the root message and every reply — from an enabled channel, however old it is. Use it on a search_slack_messages hit or a channel read's replies_omitted thread. Returns the messages with their links and files (each file with a download_url for attach_pdf_to_paper or import_paper_from_url), and exact URL/DOI matches to sources already in ForeverLM under library_matches, which are already in the library: call get_source_content before discussing one.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "channel_id": ["type": "string", "description": "The channel the thread is in, from a search hit or channel read."],
                        "thread_ts": ["type": "string", "description": "The thread's root timestamp, e.g. 1788740520.000100 — the thread_ts on a search hit or channel-read thread."],
                    ],
                    "required": ["channel_id", "thread_ts"],
                ]
            ),
            MCPToolDef(
                name: "search_slack_messages",
                description: "Search messages and files live across every Slack channel the learner has enabled, in every connected workspace, as far back as Slack keeps. This is how to find a specific article, paper, PDF or message someone posted: one call replaces reading channels one at a time, and it reaches material older than any channel read carries. Slack matches whole words, so search a distinctive phrase, a surname, a journal name, part of the title, a URL or DOI fragment, or a file name; if nothing matches, try fewer words before concluding it was never posted. Each message hit carries channel_id and thread_ts: call read_slack_thread with them to read the whole thread, which is where a linked article's full text or PDF usually is. Files carry a download_url that ForeverLM fetches as the learner (attach_pdf_to_paper or import_paper_from_url). Hits from channels the learner has not enabled are counted, never shown. If the result says Slack must be reconnected for search, tell the learner exactly that and fall back to read_slack_channel for this turn. IMPORTANT: every item in library_matches is already in the ForeverLM library; call get_source_content with its source_id before discussing one. ForeverLM reads as the learner and never posts, replies, or reacts.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words to search for. Slack search syntax such as from:@name or has:link is allowed."],
                        "limit": ["type": "integer", "description": "Most message hits (and, separately, file hits) to return. Defaults to 20, maximum 50."],
                        "channel_id": ["type": "string", "description": "Restrict the search to one enabled channel."],
                        "since_days": ["type": "integer", "description": "Only messages and files newer than this many days. Omit to search everything."],
                        "sort": ["type": "string", "enum": ["relevance", "newest"], "description": "Order of hits. Defaults to relevance."],
                    ],
                    "required": ["query"],
                ]
            ),
            MCPToolDef(
                name: "get_linear_issue",
                description: "Read one Linear issue live and in full: title, description, state, priority, assignee, labels, project, team, URL, dates, sub-issues, and every comment. Takes an identifier such as ENG-123 or an issue id. Linear tools are the only way into Linear: nothing from it is stored in the library. ForeverLM reads Linear as the learner through a read-only grant and cannot comment, assign, or change anything; point the learner at the issue's url to act.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "issue": ["type": "string", "description": "Issue identifier such as ENG-123, or the issue id, from a search hit or a list."],
                        "workspace": ["type": "string", "description": "Read one connected Linear workspace, by name, URL key or id. Omit to read every connected workspace; each result then says which one it came from."],
                    ],
                    "required": ["issue"],
                ]
            ),
            MCPToolDef(
                name: "search_linear_issues",
                description: "Search the learner's Linear workspaces live (all connected ones unless workspace names one) for issues by words, ranked by relevance, optionally within one team. This is how to find an issue by what it is about rather than by identifier. Each hit carries its identifier for get_linear_issue. Read-only: ForeverLM never writes to Linear.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "term": ["type": "string", "description": "Words from the issue's title or description, an identifier, or a name."],
                        "workspace": ["type": "string", "description": "Read one connected Linear workspace, by name, URL key or id. Omit to read every connected workspace; each result then says which one it came from."],
                        "team_key": ["type": "string", "description": "Restrict to one team by its key (the ENG in ENG-123), from list_linear_teams."],
                        "limit": ["type": "integer", "description": "Most issues to return. Defaults to 25, maximum 100."],
                    ],
                    "required": ["term"],
                ]
            ),
            MCPToolDef(
                name: "list_linear_issues",
                description: "List Linear issues live, most recently updated first, filtered by team, workflow state type, assignment to the learner, project, or how recently they changed. Use it for what is in progress for a team or what is assigned to the learner; to find an issue by words, call search_linear_issues. Read-only: ForeverLM never writes to Linear.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_key": ["type": "string", "description": "Team key such as ENG, from list_linear_teams."],
                        "state_type": ["type": "string", "enum": ["triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate"], "description": "Workflow state type. started is in progress; unstarted is todo."],
                        "assigned_to_me": ["type": "boolean", "description": "Only issues assigned to the learner."],
                        "updated_since_days": ["type": "integer", "description": "Only issues changed within this many days."],
                        "project": ["type": "string", "description": "Only issues in this project, by id or slug_id from list_linear_projects."],
                        "workspace": ["type": "string", "description": "Read one connected Linear workspace, by name, URL key or id. Omit to read every connected workspace; each result then says which one it came from."],
                        "limit": ["type": "integer", "description": "Most issues to return. Defaults to 25, maximum 100."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "list_linear_teams",
                description: "List the teams in the learner's connected Linear workspaces (every one unless workspace names one) with their keys, names, descriptions and issue counts. A team's key is the prefix of its issue identifiers (ENG in ENG-123) and the team_key the other Linear tools take. Read-only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "workspace": ["type": "string", "description": "Read one connected Linear workspace, by name, URL key or id. Omit to read every connected workspace; each result then says which one it came from."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "list_linear_projects",
                description: "List Linear projects live, most recently updated first, with status, health, lead, teams, progress, start and target dates. Optionally filter by team key or status type. Read-only: ForeverLM never writes to Linear.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_key": ["type": "string", "description": "Only projects a team with this key can see, from list_linear_teams."],
                        "status_type": ["type": "string", "enum": ["backlog", "planned", "started", "paused", "completed", "canceled"], "description": "Project status type."],
                        "workspace": ["type": "string", "description": "Read one connected Linear workspace, by name, URL key or id. Omit to read every connected workspace; each result then says which one it came from."],
                        "limit": ["type": "integer", "description": "Most projects to return. Defaults to 25, maximum 100."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_linear_project",
                description: "Read one Linear project live and in full: description and content, status, health, lead, teams, progress and dates, its issues summarised by state type and listed, its recent project updates, and its comments. Takes the project's id or slug_id (the token at the end of its URL). Read-only: ForeverLM never writes to Linear.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "Project id or slug_id, from list_linear_projects or the project's URL."],
                        "workspace": ["type": "string", "description": "Read one connected Linear workspace, by name, URL key or id. Omit to read every connected workspace; each result then says which one it came from."],
                    ],
                    "required": ["project"],
                ]
            ),
            MCPToolDef(
                name: "list_github_repositories",
                description: "List the GitHub repositories ForeverLM can read live, across every organisation and account where the ForeverLM GitHub App is installed, most recently pushed first, optionally filtered by words in the name or description. Each entry carries the owner/repo name the other GitHub tools take. GitHub tools are the only way into GitHub: nothing from it is stored in the library. ForeverLM reads GitHub as the learner through a read-only grant and cannot write, comment, push or merge.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words from the repository's name or description. Omit to list everything."],
                        "limit": ["type": "integer", "description": "Most repositories to return. Defaults to 50, maximum 100."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_github_repository",
                description: "Read one GitHub repository live: description, default branch, language, visibility, topics, stars, open issue count, dates and URL, its README, and the entries at the top level. Start here before listing files or reading code. Read-only: ForeverLM reads GitHub as the learner through a read-only grant and never writes to it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL such as https://github.com/owner/repo."],
                        "ref": ["type": "string", "description": "Branch, tag or commit to read at. Defaults to the default branch."],
                    ],
                    "required": ["repository"],
                ]
            ),
            MCPToolDef(
                name: "list_github_files",
                description: "List the files and directories at a path in a GitHub repository live, with each entry's type, size and path for read_github_file. Set recursive to walk the whole tree below the path in one call (capped, so a large tree is truncated with a note). Read-only: ForeverLM never writes to GitHub.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "path": ["type": "string", "description": "Directory path within the repository. Omit for the root."],
                        "ref": ["type": "string", "description": "Branch, tag or commit. Defaults to the default branch."],
                        "recursive": ["type": "boolean", "description": "Walk every directory below path instead of listing one level."],
                    ],
                    "required": ["repository"],
                ]
            ),
            MCPToolDef(
                name: "read_github_file",
                description: "Read one text file from a GitHub repository live, with its path, size, ref and content. Binary files are described, not returned; a very large file is truncated with a note. Read-only: ForeverLM reads GitHub as the learner through a read-only grant and cannot change a file.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "path": ["type": "string", "description": "The file's path within the repository, from list_github_files or search_github_code."],
                        "ref": ["type": "string", "description": "Branch, tag or commit. Defaults to the default branch."],
                    ],
                    "required": ["repository", "path"],
                ]
            ),
            MCPToolDef(
                name: "search_github_code",
                description: "Search one GitHub repository's code live for words, an identifier or a phrase, returning each matching file's path with the matching fragments. GitHub indexes the default branch only, so this cannot see other branches; read a file at a branch with read_github_file instead. Read-only: ForeverLM never writes to GitHub.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "query": ["type": "string", "description": "Words, an identifier, or a quoted phrase. GitHub code-search qualifiers such as path: or language: are allowed."],
                        "limit": ["type": "integer", "description": "Most files to return. Defaults to 20, maximum 50."],
                    ],
                    "required": ["repository", "query"],
                ]
            ),
            MCPToolDef(
                name: "list_github_issues",
                description: "List a GitHub repository's issues live, most recently updated first, filtered by state, labels, or how recently they changed. Pull requests are excluded; call list_github_pull_requests for those. Each entry carries its number for get_github_issue. Read-only: ForeverLM reads GitHub as the learner through a read-only grant and cannot comment, label, assign or close.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "state": ["type": "string", "enum": ["open", "closed", "all"], "description": "Issue state. Defaults to open."],
                        "labels": ["type": "string", "description": "Only issues carrying every one of these labels, comma-separated."],
                        "since_days": ["type": "integer", "description": "Only issues updated within this many days."],
                        "limit": ["type": "integer", "description": "Most issues to return. Defaults to 30, maximum 100."],
                    ],
                    "required": ["repository"],
                ]
            ),
            MCPToolDef(
                name: "get_github_issue",
                description: "Read one GitHub issue live and in full: title, body, state, author, assignees, labels, milestone, dates, URL, and every comment. Takes the issue number (the 42 in #42 or at the end of its URL). Read-only: ForeverLM never writes to GitHub; point the learner at the issue's url to act.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "number": ["type": "integer", "description": "The issue number, from list_github_issues or the issue's URL."],
                    ],
                    "required": ["repository", "number"],
                ]
            ),
            MCPToolDef(
                name: "list_github_pull_requests",
                description: "List a GitHub repository's pull requests live, most recently updated first, filtered by state. Each entry carries its number for get_github_pull_request, with title, author, branches, draft and merged state, and dates. Read-only: ForeverLM reads GitHub as the learner through a read-only grant and cannot review, approve or merge.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "state": ["type": "string", "enum": ["open", "closed", "all"], "description": "Pull request state. Defaults to open; closed includes merged."],
                        "limit": ["type": "integer", "description": "Most pull requests to return. Defaults to 30, maximum 100."],
                    ],
                    "required": ["repository"],
                ]
            ),
            MCPToolDef(
                name: "get_github_pull_request",
                description: "Read one GitHub pull request live and in full: title, body, state, author, reviewers, head and base branches, commit and change statistics, the files changed with their per-file additions and deletions, its comments and its review comments. Takes the pull request number. Read-only: ForeverLM never writes to GitHub; point the learner at the pull request's url to act.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "number": ["type": "integer", "description": "The pull request number, from list_github_pull_requests or its URL."],
                    ],
                    "required": ["repository", "number"],
                ]
            ),
            MCPToolDef(
                name: "list_github_commits",
                description: "List a GitHub repository's commits live, newest first, on a branch, tag or commit, optionally only those touching one path or made within the last days. Each entry carries sha, message, author, date and URL. Read-only: ForeverLM reads GitHub as the learner through a read-only grant and never pushes.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "repository": ["type": "string", "description": "owner/repo, or a github.com URL."],
                        "ref": ["type": "string", "description": "Branch, tag or commit to list from. Defaults to the default branch."],
                        "path": ["type": "string", "description": "Only commits that touch this file or directory."],
                        "since_days": ["type": "integer", "description": "Only commits made within this many days."],
                        "limit": ["type": "integer", "description": "Most commits to return. Defaults to 30, maximum 100."],
                    ],
                    "required": ["repository"],
                ]
            ),
            MCPToolDef(
                name: "search_notion",
                description: "Search the Notion pages and databases the learner shared with ForeverLM live, by words in their titles, or list what changed most recently when no words are given. Each result carries kind (page or database), id, title, url, parent and last_edited_time; pass kind to search only pages or only databases. Call it first to find a page or database's id, then get_notion_page or query_notion_database. Notion tools are the only way into Notion: nothing from it is stored in the library, and only pages the learner shared with the ForeverLM connection are visible. Read-only: ForeverLM reads Notion as the learner through a read-only connection and cannot create, edit, move or comment.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words from page and database titles. Omit to list the most recently edited."],
                        "workspace": ["type": "string", "description": "Read one connected Notion workspace, by name or id. Omit to read every connected workspace; each result then says which one it came from."],
                        "kind": ["type": "string", "enum": ["page", "database"], "description": "Search only pages or only databases. Omit for both."],
                        "limit": ["type": "integer", "description": "Most results to return. Defaults to 25, maximum 100."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_notion_page",
                description: "Read one Notion page live and in full: title, url, icon, parent, dates, every property flattened to plain values, and its content rendered as text (headings, lists, to-dos, quotes, callouts, code, tables, and the addresses of images and files) with nested blocks indented. Sub-pages appear as [Page: title] (id) lines to read with another call. Content is cut at 400 blocks or 60,000 characters (content_truncated). Takes the page's id or its Notion URL. Read-only: ForeverLM reads Notion as the learner through a read-only connection and cannot create, edit, move or comment; point the learner at the url to act.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "page": ["type": "string", "description": "The page's id (dashed or not), or its Notion URL, from search_notion or query_notion_database."],
                        "include_content": ["type": "boolean", "description": "Render the page's blocks as text. Defaults to true; false returns the properties alone."],
                        "workspace": ["type": "string", "description": "Read one connected Notion workspace, by name or id. Omit to read every connected workspace; each result then says which one it came from."],
                    ],
                    "required": ["page"],
                ]
            ),
            MCPToolDef(
                name: "list_notion_databases",
                description: "List the Notion databases the learner shared with ForeverLM live, most recently edited first, optionally filtered by words in their titles. Each carries id, title, description, url, parent, database_type and its property names; the id is what get_notion_database and query_notion_database take. Read-only: ForeverLM reads Notion as the learner through a read-only connection and cannot create, edit, move or comment.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words from database titles. Omit to list them all."],
                        "workspace": ["type": "string", "description": "Read one connected Notion workspace, by name or id. Omit to read every connected workspace; each result then says which one it came from."],
                        "limit": ["type": "integer", "description": "Most databases to return. Defaults to 25, maximum 100."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_notion_database",
                description: "Read one Notion database's schema live: title, description, url, and every property with its type and, for selections and statuses, the options it offers — the names a filter for query_notion_database uses. Takes the database's id or its Notion URL; a database with several data sources lists them so one can be chosen. Read-only: ForeverLM reads Notion as the learner through a read-only connection and cannot create, edit, move or comment.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "database": ["type": "string", "description": "The database's id (dashed or not), or its Notion URL, from list_notion_databases or search_notion."],
                        "workspace": ["type": "string", "description": "Read one connected Notion workspace, by name or id. Omit to read every connected workspace; each result then says which one it came from."],
                    ],
                    "required": ["database"],
                ]
            ),
            MCPToolDef(
                name: "query_notion_database",
                description: "Read a Notion database's rows live, each a page with its properties flattened to plain values, with Notion's own filter and sorts passed through unchanged (filter: {property, <type>: {…}} with and/or compounds; sorts: [{property or timestamp, direction}]). Pages of 25 by default, 100 at most; pass next_cursor back as cursor for the next page. Call get_notion_database first for the property names and options a filter needs. Read-only: ForeverLM reads Notion as the learner through a read-only connection and cannot create, edit, move or comment.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "database": ["type": "string", "description": "The database's id (dashed or not), or its Notion URL."],
                        "filter": ["type": "object", "description": "A Notion database filter object, such as {\"property\": \"Status\", \"status\": {\"equals\": \"Done\"}} or an and/or compound of them."],
                        "sorts": ["type": "array", "items": ["type": "object"], "description": "Notion sort objects, such as [{\"property\": \"Due\", \"direction\": \"ascending\"}]."],
                        "limit": ["type": "integer", "description": "Most rows to return. Defaults to 25, maximum 100."],
                        "cursor": ["type": "string", "description": "next_cursor from the previous page."],
                        "workspace": ["type": "string", "description": "Read one connected Notion workspace, by name or id. Omit to read every connected workspace; each result then says which one it came from."],
                    ],
                    "required": ["database"],
                ]
            ),
            MCPToolDef(
                name: "create_x_post",
                description: "Publish a post on X (Twitter) as the connected ForeverLM user, optionally as a reply to another post. This posts publicly and immediately — always show the user the exact text and get their explicit confirmation before calling. Requires the X plugin to be signed in with posting permission (Plugins → X); read-only sessions from before posting support must reconnect once. With one X account connected it posts as that account; with several, pass account (the user id or @username from get_plugin_connections) — it is required, and the account named is the person the post is published as. Returns the new post's id and URL.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The post text, exactly as it should appear. Standard accounts are limited to 280 characters; the X API rejects anything longer."],
                        "reply_to_post_id": ["type": "string", "description": "Optional id of an existing post to reply to (the numeric id from its URL)."],
                        "account": ["type": "string", "description": "The X account to post as: its user id or @username from get_plugin_connections. Optional when only one account is connected, required when several are."],
                    ],
                    "required": ["text"],
                ]
            ),
            MCPToolDef(
                name: "transcribe_meeting_recording",
                description: "Transcribe a meeting session's recording with managed OpenAI speech-to-text and attach the transcript to the session. Downloads the recording from Drive, splits long audio into bounded sequential chunks, and sends them through ForeverLM's managed proxy; the OpenAI key stays server-side. Use get_meeting_group to find session source ids. A long recording takes minutes; cancel_ai_work stops it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Meeting session source id (from get_meeting_group) that has a recording artifact."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "generate_source_audio",
                description: "Generate text-to-speech audio files for sources in ForeverLM — the sidebar's Generate Audio, for many sources at once. Select by source_ids, by book_ids (every chapter of a book, in reading order; ids from list_sources), and/or by source_types (e.g. [\"book\"] for every book in the library). Uses the voice the learner chose in ForeverLM Settings and the same metered route the app uses; sources that already have audio are skipped, never re-billed. Two-step when it costs money: the first call returns status awaiting_confirmation with an estimate (characters, listening time, price, model) and starts nothing — show the learner the estimate, and only after they explicitly agree call again with the same selection and confirm_cost: true. Free voices start immediately. Generation runs in the app a couple of sources at a time and continues while ForeverLM is open; follow it with get_source_audio_status and stop it with cancel_source_audio_generation. Podcasts, videos, and meetings have their own audio and are refused.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Individual source ids to narrate, in the order to generate them.",
                        ],
                        "book_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Books to narrate whole: the book_id values list_sources shows (a book's exact title is also accepted). Chapters are queued in reading order.",
                        ],
                        "source_types": [
                            "type": "array",
                            "items": ["type": "string", "enum": ["book", "article", "paper", "course", "manual", "x_post"]],
                            "description": "Every ready source of these types that has no audio yet. [\"book\"] means every book in the library.",
                        ],
                        "confirm_cost": [
                            "type": "boolean",
                            "description": "Pass true only after the learner has seen the estimate from a previous call with the same selection and explicitly agreed to the spend. Defaults to false, which quotes and starts nothing when the run would cost money.",
                        ],
                        "allow_unsupported_languages": [
                            "type": "boolean",
                            "description": "Generate a source even when no available voice speaks its language (it will be mispronounced). Defaults to false, which skips such sources and says why.",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_source_audio_status",
                description: "Report on text-to-speech audio generation started with generate_source_audio: what is generating now, what is queued, and what finished, failed, was skipped, or was cancelled, with reasons. Pass source_ids to also learn, for specific sources, whether audio already exists and where they stand in the queue. Also lists sources the learner is generating from the app itself.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional source ids to report on individually.",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "cancel_source_audio_generation",
                description: "Stop text-to-speech audio generation queued or running through generate_source_audio, for specific source_ids or everything with all: true. Chunks that already finished stay cached, so generating those sources again later does not pay for them twice.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Sources to stop.",
                        ],
                        "all": [
                            "type": "boolean",
                            "description": "Stop every queued and generating source. Defaults to false.",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_automatic_audio_settings",
                description: "Read the learner's automatic audio settings — set only from chat through set_automatic_audio_settings; the Settings window has no pane for them: for every kind automation covers — articles, papers, books, courses and explainers — whether text-to-speech audio is generated as soon as a source of that kind is ready (enabled), its optional natural-language rule (filter), and how many of that kind have no audio yet with the estimated characters and price; the selected voice with its rate; whether automation may run on that voice at all (a free OpenRouter voice always, a priced one only after allow_paid_voices, an unpriced voice or another provider never), the paid-voice consent and, for a priced voice, the quote consenting would start. Explainers are article-typed sources with a switch of their own: with it on, generate_explainer and the Mac's Explain button start an explainer's audio with the selected voice without asking about cost. The switches, rules and consent follow the learner's account to their other devices.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_automatic_audio_settings",
                description: "Change automatic audio — the only way to set it; the Settings window has no pane for it. Use it when the learner asks for audio to be made on its own: “always generate audio for articles from Martin Picard” is kind article with filter “articles where Martin Picard is an author” and enabled true, in one call. kind with enabled true switches automatic audio on for that kind — every source of it already in the library without audio starts generating now, and every later one follows — and is refused while the selected voice is not one automation may spend on; enabled false switches it off. kind with filter saves the kind's natural-language rule, judged from each source's title, author, journal, year, collection, URL and description: the rule is evaluated over the kind's pending sources first and saved only when that succeeds, an empty string clears it, and the response lists what matched. allow_paid_voices is the account's consent to let automatic audio use a priced voice; true is a spending decision, so read get_automatic_audio_settings first and put its paid_consent_quote to the learner before passing it, and false stops a paid run in flight. Turning a kind on with a priced voice is likewise something to confirm with the learner: the response's kind row carries the backlog and its price. Explainers is the switch for “always generate audio for explainers”: on, generate_explainer starts the audio without a quote. Returns the settings with changed. The choice follows the learner's account.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": MCPDataStore.automaticAudioKinds, "description": "Which switch: article, paper, book, course or explainer, as get_automatic_audio_settings lists them. Required with enabled or filter."],
                        "enabled": ["type": "boolean", "description": "true: generate audio automatically for every ready source of this kind, now and from then on. false: stop doing so for this kind."],
                        "filter": ["type": "string", "description": "An optional natural-language rule narrowing which sources of this kind are narrated, such as “papers about mitochondria”. Checked against the kind's pending sources before it is saved; an empty string removes the rule."],
                        "allow_paid_voices": ["type": "boolean", "description": "true: automatic audio may run on the selected paid voice, billing the learner's own OpenRouter key for every source a switched-on kind narrates. false: revoke that consent; a paid run in progress stops."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "attach_meeting_artifact",
                description: "Attach a local text file (transcript, notes, chat log, or other attachment) to a meeting session source as an additional artifact. The text becomes a section of the session's content (ordered transcript → notes → chat) and is listed with the session's artifacts, so one meeting can hold multiple sources. Re-attaching the same kind replaces that section. Use session source ids from get_meeting_group.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Meeting session source id (from get_meeting_group)."],
                        "file_path": ["type": "string", "description": "Absolute local path to a text, Markdown, VTT, or SRT file."],
                        "kind": ["type": "string", "enum": ["transcript", "notes", "chat", "attachment"], "description": "Artifact kind. Defaults to transcript."],
                    ],
                    "required": ["source_id", "file_path"],
                ]
            ),
            MCPToolDef(
                name: "import_meeting_transcript_files",
                description: "Import meeting transcripts from JSON files on disk into a recurring meeting group. Each .json file in folder_path holds one session: {\"title\", \"started_at\" (ISO 8601, optional), \"transcript\", \"notes\" (optional), \"chat\" (optional), \"url\" (optional)}. Useful for transcripts exported from Read AI or similar tools — the assistant is the plugin; ForeverLM never fetches from those services itself. Already-imported sessions are skipped, never duplicated.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_title": ["type": "string", "description": "Display name for the meeting group, e.g. the recurring meeting's name."],
                        "folder_path": ["type": "string", "description": "Absolute path to a folder of .json transcript files readable by the app."],
                        "source": ["type": "string", "enum": ["readai", "local"], "description": "Where the transcripts came from. \"readai\" tags sessions with the Read AI origin so re-imports of the same meetings dedup cleanly. Defaults to local."],
                    ],
                    "required": ["group_title", "folder_path"],
                ]
            ),
        ]
    }
}
