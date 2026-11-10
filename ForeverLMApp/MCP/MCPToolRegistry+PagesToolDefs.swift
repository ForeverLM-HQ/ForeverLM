// MCPToolRegistry: the pages tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var pagesToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "list_docs",
                description: "List canonical Markdown Docs. Omit notebook_id for the global collection, or pass an explicit Notebook ID to list only Docs linked to that Notebook. A Doc whose kind is google_doc, claude_artifact or codex_site is a linked page — a Google Doc, a Claude artifact or a Codex site: read-only here, with its URL in linked_url. space_id and space_name name the learner's space of pages the Doc is in (list_spaces), null when it is in none.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "create_doc",
                description: "Create one globally addressable Markdown Doc. Only for a document the learner asked for or that has no existing home: material meant for a Doc that already exists — integrate this, fold that in, update the report — belongs in that Doc through edit_doc (or write_doc for a short one), never in a new companion Doc. A home Notebook is organizational only; notebook_ids controls every Notebook that uses the same canonical document. Markdown may link to another Doc as [Title](foreverlm://doc/<doc_id>) and to a notebook as [Title](foreverlm://notebook/<notebook_id>); ForeverLM opens those in place. Cite with footnotes, never in the prose: put a marker after the claim — `…rare in aging human brain.[^1]` — and write the note at the end of the Markdown as the source's title linked to it, with a short byline after a dash: `[^1]: [Ultra-sensitive sequencing reveals an age-related increase in somatic mitochondrial mutations](https://doi.org/10.1371/journal.pgen.1003794) — Kennedy et al., PLoS Genet, 2013`. One note may name several sources, and a library source without a web address is linked as [Title](foreverlm://source/<source_id>). Never write an author-year citation such as (Kennedy et al., 2013), linked or not, and never close with a Sources or References list: the notes are the Doc's sources. ForeverLM draws the marker as a small number in the sentence; pointing at it shows each source its note names, with a check when the source is already in the Doc's library (by URL, DOI or arXiv id — a team Doc asks the team library, a Doc in My Library asks My Library) and Add to Sources when it is not.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Doc title."],
                        "home_notebook_id": ["type": "string", "description": "Optional organizational home Notebook ID."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Notebooks to link. The home Notebook is added automatically."],
                        "markdown": ["type": "string", "description": "Initial complete Markdown content. Defaults to empty."],
                        "is_draft": ["type": "boolean", "description": "Whether the new Doc starts as a draft. Defaults to false (Production)."],
                    ],
                    "required": ["title"],
                ]
            ),
            MCPToolDef(
                name: "read_doc",
                description: "Read a canonical Markdown Doc and its SHA-256 revision. Omit start/length for the complete body, or page through a large Doc by character range without copying it into chat context. Pass the revision to write_doc before replacing it. For a linked page (kind google_doc, claude_artifact or codex_site) the body is ForeverLM's read-only text copy and the result carries linked_url.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "start": ["type": "integer", "minimum": 0, "description": "Optional zero-based character offset."],
                        "length": ["type": "integer", "minimum": 1, "maximum": 50000, "description": "Optional number of characters to return (maximum 50,000)."],
                        "resolve_references": ["type": "boolean", "description": "Return the Markdown with the notes grammar resolved, as a reader outside ForeverLM sees it: each ((id)) block reference as that block's words, each {{embed: ((id))}} as the block and what is nested under it, [[Title]] and #tag links as their words, and the ` ^id` block markers removed. For reading only: edit_doc and write_doc work on the stored Markdown, which read_doc returns without it; start and length then count in the resolved text. Defaults to false."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "list_doc_chats",
                description: "List the chats a Doc's passages started, with the exact quote each conversation was opened on. Use this to find the conversation that already covered a passage instead of starting a second one about it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "link_doc_passage_to_chat",
                description: "Record that a chat session is about a specific passage of a Doc. The app writes this automatically when a passage is highlighted and Chat is opened on it; call it when a conversation arrived at a Doc some other way, so the Doc shows the discussion its passage produced.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "session_id": ["type": "string", "description": "Chat session ID from get_review_sessions."],
                        "quote": ["type": "string", "description": "The exact passage the conversation is about. Matched against the current Doc to position the link; a quote the Doc no longer contains still links, without a position."],
                        "section_title": ["type": "string", "description": "Optional heading the passage sits under."],
                    ],
                    "required": ["doc_id", "session_id", "quote"],
                ]
            ),
            MCPToolDef(
                name: "list_doc_comments",
                description: "List the comment threads on a Doc — the page's Comments panel in ForeverLM — in the order of their passages: each thread's comment_id, the quote (the words of the page it is about), whether it is resolved, and its messages oldest first (comment_id, author, by_assistant, body, created_at, updated_at). The page marks each open thread's words; a resolved thread is listed under Resolved and no longer marked. Pass include_resolved false to list only open threads.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "include_resolved": ["type": "boolean", "description": "Include resolved threads. Defaults to true."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "comment_on_doc",
                description: "Comment on a Doc as its Comments panel does, signed Assistant (never as the learner). With doc_id and quote, start a thread on those words of the page: quote them exactly as they read, a phrase or a sentence or two (at most 1,000 characters); the page marks the first place they occur, and a thread whose words are not in the page says Original text unavailable. With reply_to (a comment_id from list_doc_comments), reply in that comment's thread instead; doc_id and quote are then not needed. A team's page is refused: the learner comments there in the app. Use it when the learner asks for comments on a page, or to answer a thread they started.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs, for a new thread."],
                        "quote": ["type": "string", "description": "The exact words of the page the new thread is about."],
                        "body": ["type": "string", "description": "The comment's words."],
                        "reply_to": ["type": "string", "description": "Optional comment_id from list_doc_comments: reply in that comment's thread instead of starting one."],
                    ],
                    "required": ["body"],
                ]
            ),
            MCPToolDef(
                name: "update_doc_comment",
                description: "Change one comment on a Doc: body rewrites its words (only when the learner asks, for a comment that is not the assistant's own), resolved true resolves its thread and false reopens it (a resolved thread is no longer marked in the page and moves under Resolved in Comments). Pass body, resolved, or both. A team's page is refused.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "comment_id": ["type": "string", "description": "comment_id from list_doc_comments."],
                        "body": ["type": "string", "description": "Optional new words for the comment."],
                        "resolved": ["type": "boolean", "description": "Optional: true resolves the comment's thread, false reopens it."],
                    ],
                    "required": ["comment_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_doc_comment",
                description: "Delete a comment on a Doc, as the Comments panel's Delete comment does: its replies remain, and when it was the comment that opened its thread, the first reply opens the thread from then on with the same passage. whole_thread true deletes the thread the comment is in and every message in it (Delete thread). Cannot be undone. A team's page is refused. Confirm with the learner first unless the comment is the assistant's own.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "comment_id": ["type": "string", "description": "comment_id from list_doc_comments."],
                        "whole_thread": ["type": "boolean", "description": "Delete the comment's whole thread instead of the one comment. Defaults to false."],
                    ],
                    "required": ["comment_id"],
                ]
            ),
            MCPToolDef(
                name: "unlink_doc_chat",
                description: "Forget one passage-to-chat link from list_doc_chats. The Doc and the conversation both survive; only the claim that they are related is removed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "link_id": ["type": "string", "description": "link_id from list_doc_chats."],
                    ],
                    "required": ["link_id"],
                ]
            ),
            MCPToolDef(
                name: "write_doc",
                description: "Revision-safely replace a Doc's canonical Markdown — the whole body, so only for a short Doc or a complete rewrite. To change parts of a Doc, especially a long one whose body would not fit in a tool call, use edit_doc instead. Every linked Notebook immediately sees the same edit. A published Doc's page is not re-rendered unless publish is true: without it the result says the page is stale and publish_doc updates it; with it a Doc that already has a page gets the page updated in the same call, at the same address with the same readers (a Doc with no page is not published by it). Refused for a linked page (kind google_doc, claude_artifact or codex_site), whose text is edited where it lives — the refusal says how to refresh ForeverLM's copy (link_page with text), make it an editable Doc (unlink_page), or make it ForeverLM's own published page (adopt_page). Markdown may link to another Doc as [Title](foreverlm://doc/<doc_id>) and to a notebook as [Title](foreverlm://notebook/<notebook_id>); ForeverLM opens those in place. Cite with footnotes, never in the prose: put a marker after the claim — `…rare in aging human brain.[^1]` — and write the note at the end of the Markdown as the source's title linked to it, with a short byline after a dash: `[^1]: [Ultra-sensitive sequencing reveals an age-related increase in somatic mitochondrial mutations](https://doi.org/10.1371/journal.pgen.1003794) — Kennedy et al., PLoS Genet, 2013`. One note may name several sources, and a library source without a web address is linked as [Title](foreverlm://source/<source_id>). Never write an author-year citation such as (Kennedy et al., 2013), linked or not, and never close with a Sources or References list: the notes are the Doc's sources. ForeverLM draws the marker as a small number in the sentence; pointing at it shows each source its note names, with a check when the source is already in the Doc's library (by URL, DOI or arXiv id — a team Doc asks the team library, a Doc in My Library asks My Library) and Add to Sources when it is not.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "markdown": ["type": "string", "description": "Complete Markdown content."],
                        "expected_revision": ["type": "string", "description": "Exact revision returned by read_doc."],
                        "publish": ["type": "boolean", "description": "When the Doc has a published page, update it with this body in the same call (same address, same readers). Ignored for a Doc that is not published. Defaults to false."],
                    ],
                    "required": ["doc_id", "markdown", "expected_revision"],
                ]
            ),
            MCPToolDef(
                name: "edit_doc",
                description: "Change parts of a Doc in place without re-emitting it: each edit names the exact existing text to find and the text to put there, applied in order and all-or-nothing, and append adds Markdown at the end. This is the way to integrate, fold in, update, correct or extend an existing Doc of any length — a 200,000-character report is edited in one call that carries only the passages that change. Every find must occur exactly once (pass replace_all to change every occurrence; give more surrounding text to disambiguate); an edit that matches nowhere or in several places changes nothing and says which. Quote find text exactly as read_doc returned it, whitespace and Markdown markers included. Requires the revision from read_doc. The learner may be typing in the Doc meanwhile: when it changed after that read, the edits are applied to its newer text as long as every find still matches exactly once, and the result says doc_changed_meanwhile; an edit whose own passage changed is refused and nothing is saved. Refused for a linked page (the refusal says how to refresh ForeverLM's copy with link_page, make it an editable Doc with unlink_page, or make it ForeverLM's own published page with adopt_page). Every linked Notebook sees the same edit. A published Doc's page is not re-rendered unless publish is true: without it the result says the page is stale and publish_doc updates it; with it a Doc that already has a page gets the page updated in the same call.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "edits": [
                            "type": "array",
                            "description": "Targeted replacements, applied in order. May be empty when only append is used.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "find": ["type": "string", "description": "Exact existing text to replace. Must occur exactly once unless replace_all is true."],
                                    "replace": ["type": "string", "description": "Text to put in its place. An empty string deletes the found text."],
                                    "replace_all": ["type": "boolean", "description": "Replace every occurrence of find instead of requiring a single match. Defaults to false."],
                                ],
                                "required": ["find", "replace"],
                            ],
                        ],
                        "append": ["type": "string", "description": "Optional Markdown appended at the end of the Doc, after the edits, on a new line."],
                        "publish": ["type": "boolean", "description": "When the Doc has a published page, update it with the edited body in the same call (same address, same readers). Ignored for a Doc that is not published. Defaults to false."],
                        "expected_revision": ["type": "string", "description": "Exact revision returned by read_doc. A newer revision does not refuse the edit by itself; the find texts are checked against the newer body."],
                    ],
                    "required": ["doc_id", "expected_revision"],
                ]
            ),
            MCPToolDef(
                name: "update_doc",
                description: "Rename a Doc, change Draft/Production status, archive or restore it, hide or show it, change its optional home Notebook, or replace its complete Notebook-link set without copying the document. Omit a field to keep it unchanged; pass an empty home_notebook_id to clear the home. Archiving keeps the Doc or Site whole — body, page and Notebook links — and only takes it off the Docs and Sites lists, which show it again under Archived. Hiding is the learner's view rather than the record's state: the record does not change and no teammate sees it, but every Mac signed into the account hides it; the lists show it again only under Hidden.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "title": ["type": "string", "description": "Optional new title."],
                        "home_notebook_id": ["type": "string", "description": "Optional new home Notebook; empty clears it."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Optional complete replacement Notebook-link set."],
                        "is_draft": ["type": "boolean", "description": "Optional Draft status. False marks the Doc as Production."],
                        "is_archived": ["type": "boolean", "description": "Optional: true archives the Doc or Site, false restores it to the list. Nothing else about it changes."],
                        "is_hidden": ["type": "boolean", "description": "Optional: true hides the Doc or Site from the Docs and Sites lists on every Mac signed into this account, false shows it again. The record, its page and its team copies are untouched; only the hide itself syncs."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_doc",
                description: "Move a Doc to the Trash — the Docs pane's Move to Trash. The Doc's Markdown body and its Notebook links go with it and every linked Notebook stops seeing it; sources and chats are untouched. For a linked page (kind google_doc, claude_artifact or codex_site) this only removes the entry from Docs or Sites; the page itself is never touched. This cannot be undone through MCP, so call list_docs or read_doc first and confirm the title with the learner before deleting.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "list_doc_versions",
                description: "List the earlier versions of a Doc that this Mac keeps — the page's Page activity in ForeverLM — newest first: each one's version_id, saved_at, reason (what replaced that body: learner_edit, assistant_edit, another_device or restore), the app's summary of it and its size in bytes, with the current body's revision and size. A version is kept when an assistant or a restore replaces the body, after every ten minutes of the learner's typing, and when the page loses more than half its text at once; a page keeps at most 100 versions and 50 MB. Versions are this Mac's alone: another Mac, the iPhone and the web keep none of these. Pass version_id to read that version's Markdown, whole or by character range with start and length as read_doc pages a body. restore_doc_version makes one the page again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "version_id": ["type": "string", "description": "Optional version_id from this list: return that version's Markdown as well."],
                        "start": ["type": "integer", "minimum": 0, "description": "Optional zero-based character offset into the version_id's Markdown."],
                        "length": ["type": "integer", "minimum": 1, "maximum": 50000, "description": "Optional number of characters of the version_id's Markdown to return (maximum 50,000)."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "restore_doc_version",
                description: "Make an earlier version of a Doc its body again — Restore This Version in the page's Page activity on this Mac. The version (from list_doc_versions) is written through the ordinary save over the page's current body, which is kept as a version first: the answer names it as replaced_body_version_id, and restoring that id undoes the restore. Pass expected_revision from read_doc or list_doc_versions to refuse the restore when the page changed since you looked; without it the restore goes over whatever the page holds now. Refused for a team's page and for a linked page (kind google_doc, claude_artifact, codex_site or foreverlm_site), as in the app, and for an audio overview or a mnemonic reading, whose Markdown write_doc does not change either. A published Doc's page is not re-rendered unless publish is true. Versions are this Mac's, so only the Mac that kept them can restore one. Confirm with the learner before restoring over their page.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                        "version_id": ["type": "string", "description": "version_id from list_doc_versions."],
                        "expected_revision": ["type": "string", "description": "Optional revision from read_doc or list_doc_versions' current: the restore is refused when the page no longer has it."],
                        "publish": ["type": "boolean", "description": "When the Doc has a published page, update it with the restored body in the same call (same address, same readers). Ignored for a Doc that is not published. Defaults to false."],
                    ],
                    "required": ["doc_id", "version_id"],
                ]
            ),
            MCPToolDef(
                name: "list_spaces",
                description: "List the learner's spaces of pages: the Spaces in the sidebar of ForeverLM's Space, which group pages around a topic or a project. Each space has an id, a name (a leading emoji is its icon) and the docs in it by title, each with its id, title, kind, is_hidden and updated_at; pages in the Trash are left out, and the spaces in the Space's Trash are listed under in_trash (id, name, trashed_at), their pages in no space until restored. A page, linked Google Doc, site or reading is in one space at most, or in none. Spaces are the learner's own grouping: they change nothing about a Doc and follow the learner's account to their other devices. The teams are the shared spaces and are listed by list_teams, not here. update_space changes spaces; list_docs names each Doc's space.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "update_space",
                description: "Change the learner's spaces of pages, the Spaces in the sidebar of ForeverLM's Space (list_spaces lists them). action create makes a space called name, moves doc_ids into it when given, and answers its id; rename gives space_id the name; trash puts space_id in the Space's Trash, where it leaves the sidebar and its pages stay in All, in no space, and restore brings it back with them; delete deletes space_id for good, and the pages in it stay, listed in All; move_docs moves doc_ids into space_id, each out of the space it was in, since a page is in one space at a time; remove_docs takes doc_ids out of whatever space each is in. Only the learner's own pages, linked Google Docs, sites and readings in no notebook can join a space, not a team's record, an animation or an audio overview. A space changes nothing about a Doc, and the change follows the learner's account to their other devices.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["create", "rename", "trash", "restore", "delete", "move_docs", "remove_docs"], "description": "What to change."],
                        "space_id": ["type": "string", "description": "Space ID from list_spaces. Required for rename, trash, restore, delete and move_docs."],
                        "name": ["type": "string", "description": "The space's name, for create and rename. A leading emoji is its icon."],
                        "doc_ids": ["type": "array", "items": ["type": "string"], "description": "Doc IDs from list_docs: the pages to move in (create, move_docs) or take out of their space (remove_docs)."],
                    ],
                    "required": ["action"],
                ]
            ),
            MCPToolDef(
                name: "link_page",
                description: "Put a page in ForeverLM from its link — the app's Link a Google Doc… in Docs and Link a Site… in Sites: a Google Doc (docs.google.com/document/d/…) lands in Docs; a Claude artifact (claude.ai/code/artifact/… or claude.ai/public/artifacts/…) or a Codex site (….chatgpt.site) lands in the Sites section. The page opens in ForeverLM as itself and the entry is read-only here (write_doc refuses it). ForeverLM takes the page's title and a text copy for chat and review when the doc is next opened in the app — a Google Doc's export, or the visible text of a rendered artifact or site — so until then read_doc returns an empty body and the title is the placeholder unless one is passed. If you can read the page yourself (Claude Code can read its own artifacts), pass its content as text so the copy is there at once. Linking a page that is already in Docs or Sites returns the existing entry, and when text is passed replaces ForeverLM's text copy with it — the way to refresh the copy after editing the page in Claude or Codex. Anything else — a Sheet, a Drive file, a site on its own domain, any other website — is refused with the reason; import those with add_source instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The page's link: a docs.google.com/document URL, a claude.ai artifact URL, or a chatgpt.site URL."],
                        "title": ["type": "string", "description": "Optional title. Omit to adopt the page's own title when the app next opens it."],
                        "text": ["type": "string", "description": "Optional initial text copy — the page's content as Markdown or plain text — held for chat and review until the app refreshes it from the page."],
                        "home_notebook_id": ["type": "string", "description": "Optional home Notebook ID from list_notebooks."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Notebooks that use this Doc as context. The home Notebook is added automatically."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "unlink_page",
                description: "Make a linked page an editable Markdown Doc again — the inverse of link_page. ForeverLM's stored text copy becomes the Markdown body; the Doc keeps its id, title and Notebook links, and write_doc accepts it from then on. The page itself is not touched. Refused for a Doc that is not a linked page.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs, with kind google_doc, claude_artifact or codex_site."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "adopt_page",
                description: "Make a linked page ForeverLM's own: in one call the linked Codex site, Claude artifact or Google Doc is unlinked into a Markdown Doc and published as a page on foreverlm.com, at the address the result returns, where write_doc and edit_doc with publish edit it from then on — from Codex, Claude or the app. The body is ForeverLM's text copy of the page unless markdown is passed; pass the page's real Markdown whenever you have it (Codex built the site, so it knows what is on it), because the text copy is what the rendered page said and not its source. readers and slug are publish_doc's. Refused for a Doc that is not a linked page, and — with nothing changed — when the Mac is not signed in with Apple. The original page is never touched; only ForeverLM's entry changes.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs, with kind codex_site, claude_artifact or google_doc."],
                        "markdown": ["type": "string", "description": "Optional. The page's complete content as Markdown, used as the Doc's body instead of ForeverLM's text copy."],
                        "readers": ["type": "array", "items": ["type": "string"], "description": "Optional. Email addresses the page is shared with; omit or pass an empty list for a page anyone with the link can read."],
                        "slug": ["type": "string", "description": "Optional custom address, the part after foreverlm.com/share/: 3–64 lowercase letters, digits and single hyphens."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "link_google_doc",
                description: "Put a Google Doc (docs.google.com/document/d/…) or another page in ForeverLM from its link, read-only, as Link a Google Doc… in Docs does. This is the older name of link_page and does exactly what it does.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "A docs.google.com/document link — share, edit or view URL."],
                        "title": ["type": "string", "description": "Optional title. Omit to adopt the Google Doc's own title when the app next opens it."],
                        "home_notebook_id": ["type": "string", "description": "Optional home Notebook ID from list_notebooks."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Notebooks that use this Doc as context. The home Notebook is added automatically."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "unlink_google_doc",
                description: "Make a linked page, such as a linked Google Doc, an editable Markdown Doc again; the page itself is not touched. This is the older name of unlink_page and does exactly what it does.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs, with a linked kind."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "publish_doc",
                description: "Publish a Doc as a page on foreverlm.com, or update the page it already has — the app's Publish to foreverlm.com…. By default anyone with the returned link can read the page; pass readers to share it with specific people instead, who enter their email address on the page and follow the link that is sent to them. The page is unlisted, and only the learner's ForeverLM account can update or take it down. It is rendered from the Doc's Markdown: cited sources stay as links and reference lines become cards; foreverlm:// links are unwrapped to their text and attached pictures are not published. Republishing keeps the same address (unless slug is passed) and, unless readers is passed, the same readers. Refused for a linked page and when the Mac is not signed in with Apple.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs or create_doc."],
                        "slug": ["type": "string", "description": "Optional. A custom address for the page, the part after foreverlm.com/share/: 3–64 lowercase letters, digits and single hyphens (for example obesity-landscape-2026). Omit to keep the current address, which is a random twelve-character one on a first publish. Passing a new slug moves the page there and its old address forwards; an address another page holds is refused."],
                        "readers": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional. The email addresses the page is shared with (at most 200). Only these people can open it: each enters their address on the page and follows the link emailed to them, and the page remembers them for thirty days. Pass an empty list to open the page to anyone with the link. Omit to leave the current readers as they are. Removing an address shuts that reader out at once. list_docs reports the current list as published_readers.",
                        ],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "unpublish_doc",
                description: "Take down a Doc's page on foreverlm.com so its link stops working — the app's Unpublish. The Doc itself stays in the library. A Doc that is not published is not an error.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "doc_id": ["type": "string", "description": "Doc ID from list_docs."],
                    ],
                    "required": ["doc_id"],
                ]
            ),
            MCPToolDef(
                name: "save_site",
                description: "Save a website — HTML, CSS, JavaScript and images you wrote — in the learner's ForeverLM library, or change one saved before. This is how a chat makes an actual site rather than a Doc. The site is kept in the library and syncs through the learner's own iCloud; it opens in the app's Sites section as itself, and chat can read its text. Nothing is put on the web: ForeverLM keeps sites in the library and never hosts one. A page the learner published elsewhere can be linked with link_page. Pass html for a one-page site, or files for several (index.html at the root is required; paths are relative, e.g. css/site.css, and are referenced from the HTML with relative links); or pass repository (owner/repo, read through the learner's GitHub plugin, text files only) with repository_path and ref to save a folder of a repo — the commit is recorded. Every page runs in a sandbox: its own files and https resources load, scripts run, forms and links work, but localStorage, cookies and same-origin storage throw, so write pages that work without them (wrap storage in try/catch). To show a source from the learner's library, write a link to foreverlm://source/<source-id> (the id from list_sources or search_sources) with the source's title as its text, standing alone as the only content of its p, li, td or div. ForeverLM draws it as the library's banner card — the source's own thumbnail, its title, and author · venue · year: the Mac renders each source's thumbnail and stores it with the site under foreverlm/, together with the card script the pages load, so the cards are part of the site; in the app a card opens Reader beside the site. A source the library holds can equally be linked by its own web address — its DOI, arXiv, publisher, YouTube or podcast page — as an ordinary https link: ForeverLM matches every address the pages link against the library (by URL, DOI or arXiv id) and draws the same card for a match; an address the library does not hold is simply the page it names. Prefer that form for a paper or page with a web address, and foreverlm://source/<id> for a source with no web address (a local PDF, a book chapter, notes). The result's linked_addresses lists the addresses that matched. Never draw your own source cards, thumbnails or Open in Reader buttons, leave the foreverlm/ files alone (they are regenerated on every save), and check unresolved_sources in the result for ids no source answers to. To change a saved site, pass site (its site_id) and only the files that change: every other file is kept as it is, so never read back or re-send files you are not changing. read_site_file without a path lists the site's files; with a path it returns one file's current text. Pass remove_files to drop files, or replace_all true to make the passed files the whole site. A new site needs index.html; an update keeps the stored one unless a new one is passed. A site kept in the library can be up to 45 MB in all, so it syncs with the record. Returns the site_id and the site's library address.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "What the site is called in ForeverLM. Required for a new site; optional when updating one."],
                        "html": ["type": "string", "description": "The entry page (index.html) as a complete HTML document. Use this for a one-page site; use files when the site has more than one file."],
                        "files": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "path": ["type": "string", "description": "The file's path inside the site: index.html, about.html, css/site.css, img/logo.png. Letters, digits, dots, hyphens and underscores; no dot segments."],
                                    "content": ["type": "string", "description": "The file's text (HTML, CSS, JavaScript, SVG, JSON). Pass exactly one of content and content_base64."],
                                    "content_base64": ["type": "string", "description": "The file's bytes as base64, for an image or font."],
                                ],
                                "required": ["path"],
                            ],
                            "description": "The site's files, at most 200 and 10 MB in all, 2 MB each. Must include index.html at the root unless html is passed.",
                        ],
                        "repository": ["type": "string", "description": "Optional. Read the files from a GitHub repository instead of passing them: owner/repo, or a github.com URL, from list_github_repositories. Text files only; images in the repo are skipped and named in the result."],
                        "repository_path": ["type": "string", "description": "Optional. The folder inside the repository that holds the site's index.html, such as site or docs/public. Defaults to the repository root."],
                        "ref": ["type": "string", "description": "Optional. The branch, tag or commit to read; defaults to the repository's default branch."],
                        "site": ["type": "string", "description": "Optional. The site to change: its site_id from an earlier save_site or the Sites list. Omit to save a new site."],
                        "remove_files": ["type": "array", "items": ["type": "string"], "description": "Optional, updates only. Stored files to drop from the site, by path. Ignored when replace_all is true."],
                        "replace_all": ["type": "boolean", "description": "Optional, default false. On an update, make the passed files the whole site and drop every stored file not passed. Off, an update keeps the stored files it does not name."],
                        "home_notebook_id": ["type": "string", "description": "Optional. The Notebook the new site's Sites entry belongs to, from list_notebooks."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Optional. Further Notebooks the entry is linked to."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "read_site_file",
                description: "Read a site or animation kept in the library. With path, one file — the current index.html before changing it, a stylesheet, a script; text comes back as content, an image as content_base64. Without path, the list of its files. Read only the files you are about to change: save_site and save_animation keep the rest.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string", "description": "The site's site_id from save_site or the Sites list (or an animation_id); its foreverlm-site:// address also resolves."],
                        "path": ["type": "string", "description": "Optional. The file's path inside the site, such as index.html or css/site.css. Omit to list the site's files."],
                    ],
                    "required": ["site"],
                ]
            ),
            MCPToolDef(
                name: "replace_site_text",
                description: "Change one passage of a site kept in the library without rewriting the page — the app's Change action on a selection in an open Site. Pass find, the text as it reads on the page (one line, or several consecutive lines such as a kicker and the heading under it; entities decoded, whitespace as rendered), and replace, the new text. ForeverLM reads the stored page, finds the passage in its HTML source — the text between tags, joined across inline markup; scripts, styles, comments and attributes never match — replaces exactly that text with the new one encoded, and saves the site with every other file kept. The passage must occur exactly once: the call is refused with the count when it appears more often (pass a longer passage) and when it is not in the source (text a script drew, or text changed since it was read). With as many lines in replace as in find, each line changes in place; otherwise the first matched element takes the whole new text and the others are emptied, tags kept. Returns the address, the path and what changed. For anything more than a passage — new markup, a new page, a stylesheet — use save_site.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string", "description": "The site's site_id from save_site or the Sites list (or an animation_id); its foreverlm-site:// address also resolves."],
                        "find": ["type": "string", "description": "The passage as it reads on the page. Several consecutive lines may be passed, one per line."],
                        "replace": ["type": "string", "description": "The new text. Empty removes the passage and keeps its tags."],
                        "path": ["type": "string", "description": "Optional. The page's path inside the site, such as about.html, or the page's foreverlm-site:// address. Defaults to index.html."],
                    ],
                    "required": ["site", "find", "replace"],
                ]
            ),
            MCPToolDef(
                name: "save_animation",
                description: "Save an animation in ForeverLM: a moving explanation of how something in a source works — the flow of electrons through the electron transport chain, the intermediates of a cycle appearing in turn, which steps happen inside the mitochondrion and which outside, a mechanism with and without a drug — drawn as code you wrote (HTML with inline SVG or Canvas and JavaScript that plays, pauses, scrubs and toggles conditions) or rendered to a video file by a tool such as Manim. The animation is kept in the learner's library and syncs through their own iCloud, plays in the app's Animations section in a sandbox (scripts run; localStorage and cookies throw, so wrap storage in try/catch), and is linked to the sources it explains. Nothing is put on the web. This is the tool whenever the learner wants to see how something works, an animation, a walkthrough of a pathway, or a mechanism in motion: never answer with a Doc, a Site or a static figure instead. Pass html for a one-file animation or files for several (index.html at the root; paths relative). A file may carry content (text), content_base64 (bytes) or local_path (a file on this Mac — the way a video rendered here is saved without travelling through the call; an animation can be up to 45 MB in all, so it syncs with the record). Exactly one video file (mp4, webm, mov, m4v) with no index.html gets a player page written around it. Pass sources — the ids of the papers or articles the animation explains, from list_sources, search_sources_semantic or the chat's attached sources; a foreverlm://source/<id> link or a DOI, arXiv or publisher address the library holds also resolves — so the paper lists its animations and the animation opens its paper; a new animation whose sources resolve to nothing is refused with the tokens, and sources: [] saves an animation about no source. Pass description: two or three sentences on what it shows and how to read it, which becomes what chat, review and search know about it. Draw the mechanism the sources describe, label every step in words, use readable text sizes, prefer SVG with requestAnimationFrame or CSS animation, load nothing from the network unless the sources need it, and add controls (play/pause, a scrubber, a toggle for each condition compared). To show a source on the page, write a link to foreverlm://source/<id> standing alone in its p, li or div: ForeverLM draws it as the library's banner card and opens Reader in the app; never draw your own cards. To change an animation saved before, pass animation (its animation_id) and only the files that change; the other stored files are kept, remove_files drops named ones, replace_all makes the passed files the whole animation, and sources passed on an update replace the linked sources.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "What the Animations list and the page call it. Required for a new animation; optional when updating one."],
                        "description": ["type": "string", "description": "Two or three sentences on what the animation shows and how to read it. Becomes the text chat, review and search know about it, together with the page's own text."],
                        "html": ["type": "string", "description": "The animation as one complete HTML document (index.html): inline SVG or Canvas, styles and script. Use files when it has more than one file."],
                        "files": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "path": ["type": "string", "description": "The file's path inside the animation: index.html, krebs.js, styles.css, animation.mp4. Letters, digits, dots, hyphens and underscores; no dot segments. With local_path it defaults to the file's own name."],
                                    "content": ["type": "string", "description": "The file's text (HTML, SVG, CSS, JavaScript, JSON). Pass exactly one of content, content_base64 and local_path."],
                                    "content_base64": ["type": "string", "description": "The file's bytes as base64, for a small image or font (at most 2 MB)."],
                                    "local_path": ["type": "string", "description": "A file on this Mac to read the bytes from — a video rendered by Manim or another tool. The Mac reads it; the bytes never travel through this call."],
                                ],
                                "required": ["path"],
                            ],
                            "description": "The animation's files, at most 200. Must include index.html at the root unless html is passed or exactly one video file is passed on its own.",
                        ],
                        "sources": ["type": "array", "items": ["type": "string"], "description": "The sources the animation explains: source ids (or unique prefixes), foreverlm://source/<id> links, or web addresses the library holds (DOI, arXiv, publisher, YouTube). Pass the attached paper's id when animating a paper. An empty list saves an animation about no source."],
                        "animation": ["type": "string", "description": "Optional. The animation to update: its animation_id from an earlier save_animation or list_animations. Omit to save a new one."],
                        "remove_files": ["type": "array", "items": ["type": "string"], "description": "Optional, updates only. Stored files to drop, by path. Ignored when replace_all is true."],
                        "replace_all": ["type": "boolean", "description": "Optional, default false. On an update, make the passed files the whole animation and drop every stored file not passed."],
                        "home_notebook_id": ["type": "string", "description": "Optional. The Notebook the new animation's entry belongs to, from list_notebooks."],
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "Optional. Further Notebooks the entry is linked to."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "list_animations",
                description: "List the animations saved in ForeverLM — every one, only those about one source (pass source_id: a source id, a foreverlm://source/<id> link, or a web address the library holds), or only those that live in one Notebook (pass notebook_id). Each entry carries its url, the sources it explains, a summary from its text copy, and the record fields list_docs reports. Use it to answer \"is there an animation of this?\" before making another, and to find the animation_id an update needs.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Optional. Only the animations about this source: its id (or a unique prefix), a foreverlm://source/<id> link, or a web address the library holds."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks: only the animations that live in it or are linked to it. Explaining one of its sources is not enough."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "list_source_artifacts",
                description: "The artifacts a source is linked to — the app's Linked in menu on a source. For a paper, an article, a chapter, a video or a meeting, lists every Doc, site and animation linked to it and how: grounded (the record's own source links name it — an animation's sources, a site's cards, a Doc's grounding, a book standing for its chapters) or cited (a Doc's body holds a reference to it — its DOI or page address, or a foreverlm://source link), both when both. Each entry carries the record fields list_docs reports plus artifact_id, linked_by and url. Nothing is inferred from wording: a Doc that discusses a paper without linking it is not listed. Use it to answer \"where have I used this paper?\" before writing about it again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "The source: its id from list_sources or search_sources_semantic (or a unique prefix), a foreverlm://source/<id> link, or a web address the library holds."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_animation",
                description: "Remove an animation saved with save_animation from the library, with its files. Confirm with the learner first; this cannot be undone except by saving the files again. Refused for a Site — delete_doc removes those.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "animation": ["type": "string", "description": "The animation's animation_id from save_animation or list_animations."],
                    ],
                    "required": ["animation"],
                ]
            ),
            MCPToolDef(
                name: "read_notebook_markdown_file",
                description: "Read one complete .md or .markdown file from a Notebook workspace. Returns its Markdown and SHA-256 revision; pass that revision to write_notebook_markdown_file before replacing the file.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "path": ["type": "string", "description": "Relative path from list_notebook_files, for example Article draft.md or Drafts/Article.md."],
                    ],
                    "required": ["notebook_id", "path"],
                ]
            ),
            MCPToolDef(
                name: "write_notebook_markdown_file",
                description: "Create or replace a Markdown artifact in a Notebook's Other files workspace. To create a new file, omit expected_revision. To edit an existing file, first call read_notebook_markdown_file and pass its exact revision; a stale or missing revision fails instead of overwriting newer work.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "path": ["type": "string", "description": "Relative .md or .markdown path inside the Notebook."],
                        "markdown": ["type": "string", "description": "Complete Markdown file content."],
                        "expected_revision": ["type": "string", "description": "Exact SHA-256 revision returned by read_notebook_markdown_file. Required when the path already exists; omit only when creating."],
                    ],
                    "required": ["notebook_id", "path", "markdown"],
                ]
            ),
            MCPToolDef(
                name: "update_notebook_notes",
                description: "Replace a Notebook's synthesis notes (markdown) — the accumulated record of what the learner understands. Use append_notebook_notes to add without replacing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "markdown": ["type": "string", "description": "Notes markdown."],
                    ],
                    "required": ["notebook_id", "markdown"],
                ]
            ),
            MCPToolDef(
                name: "append_notebook_notes",
                description: "Append markdown to a Notebook's synthesis notes without replacing existing notes.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "markdown": ["type": "string", "description": "Notes markdown to append."],
                    ],
                    "required": ["notebook_id", "markdown"],
                ]
            ),
            MCPToolDef(
                name: "split_notebook",
                description: "Split a Notebook into focused child notebooks by moving sources (and linked open questions) out of the parent pool. Each source moves to exactly one child — sources are not copied. The children are in the parent's library: a team's Notebook splits into that team. Use when a broad research thread naturally breaks into subfields.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "splits": [
                            "type": "array",
                            "description": "Child notebooks to create. Each entry needs title and source_ids; gap_ids is optional.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string", "description": "Child notebook title."],
                                    "topic": ["type": "string", "description": "Optional discovery topic. Defaults to title."],
                                    "source_ids": ["type": "array", "items": ["type": "string"], "description": "Sources to move into this child."],
                                    "gap_ids": ["type": "array", "items": ["type": "string"], "description": "Optional open-question IDs to move. Gaps linked to moved sources move automatically."],
                                ],
                                "required": ["title", "source_ids"],
                            ],
                        ],
                        "keep_parent": ["type": "boolean", "description": "Keep the parent notebook with remaining sources. Defaults to true. When false and the parent has no sources left after the split, everything else it holds (chats, Goals, tasks, Docs, courses, open questions, files) moves to the child that took the most sources and the parent is deleted."],
                    ],
                    "required": ["notebook_id", "splits"],
                ]
            ),
            MCPToolDef(
                name: "merge_notebooks",
                description: "Merge multiple Notebooks into one. The first notebook_id is the survivor; the others are folded in and deleted. Everything follows: source pools are unioned (deduped), and the merged Notebooks' chats, nested Goals, tasks, Docs, courses, scheduled tasks, Schedule placements, memory items, related-Notebook links, Ideas' links, Directions and workspace files move to the survivor. Open questions are deduped by summary, research questions unioned, and synthesis notes concatenated by default. All Notebooks must be in the same library (My Library or one team).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_ids": ["type": "array", "items": ["type": "string"], "description": "At least two notebook IDs. The first is the survivor."],
                        "title": ["type": "string", "description": "Optional new title for the merged notebook."],
                        "merge_notes": ["type": "boolean", "description": "Concatenate synthesis notes from merged notebooks. Defaults to true."],
                    ],
                    "required": ["notebook_ids"],
                ]
            ),
            MCPToolDef(
                name: "list_open_questions",
                description: "List an explicitly identified Notebook's open questions (research gaps) — the emergent spine of what the learner is chasing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "include_resolved": ["type": "boolean", "description": "Include resolved questions. Defaults to false."],
                        "status": ["type": "string", "enum": ["open", "improving", "resolved"], "description": "Optional status filter"],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "create_open_question",
                description: "Create an open question on a Notebook: a research gap the learner is chasing, with no deadline. It is NOT a Goal and never appears in the Goals tab. When the learner says \"goal\" in any form (\"set up a goal\", \"add this to my goals\", \"my goal is to understand X\"), use create_learning_goal instead — and if they named no deadline, propose one and confirm it rather than filing the goal here as a question. Questions also accumulate automatically from end_review_session after reviews.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "summary": ["type": "string", "description": "The question or thread the learner is pursuing"],
                        "source_id": ["type": "string", "description": "Optional source ID from this Notebook's pool to link the question"],
                        "severity": ["type": "number", "description": "Optional 0..1 priority or centrality"],
                        "status": ["type": "string", "enum": ["open", "improving", "resolved"], "description": "Defaults to open"],
                    ],
                    "required": ["notebook_id", "summary"],
                ]
            ),
            MCPToolDef(
                name: "update_open_question",
                description: "Update an existing open question on a Notebook (status, summary, linked source, severity).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "question_id": ["type": "string", "description": "Open question ID from list_open_questions"],
                        "summary": ["type": "string", "description": "New summary text"],
                        "source_id": ["type": "string", "description": "Link to a source in this Notebook's pool"],
                        "clear_source_link": ["type": "boolean", "description": "Remove the linked source"],
                        "severity": ["type": "number", "description": "0..1 priority or centrality"],
                        "status": ["type": "string", "enum": ["open", "improving", "resolved"], "description": "Question status"],
                    ],
                    "required": ["notebook_id", "question_id"],
                ]
            ),
        ]
    }
}
