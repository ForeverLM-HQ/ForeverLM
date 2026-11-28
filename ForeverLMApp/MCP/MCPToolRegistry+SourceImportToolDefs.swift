// MCPToolRegistry: the source import tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var sourceImportToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "add_source",
                description: "Add a non-paper source written by someone else to the knowledge base. Its content is shown verbatim in the reader, not rendered as Markdown: for something you wrote yourself, such as a report or a synthesis, use create_doc instead. Papers must use import_paper_from_url, import_local_pdf_as_paper, or the ingest-only import_connector_paper so the mandatory paper models run. A Codex site (….chatgpt.site), a Claude artifact, a Google Doc or a ForeverLM site is refused too, whatever content is passed: ForeverLM links those pages rather than scraping them — a Codex site answers an anonymous fetch with its sign-in page — so call link_page with the url instead. Convoke query results (platform.convoke.bio) are refused as well: they are answers to a live query, not pages, and are never sources. For courses/books, specify parent_group as the display title or stable group ID; both require it, because course material outside a course is never listed and a chapter outside a book is a loose row with no cover. For meetings, parent_group names the recurring series (meeting group) the session belongs to and occurred_at is when it took place; without occurred_at a meeting is dated by the moment it was added. A YouTube playlist is a course, not a source: add_source refuses a playlist url, and import_youtube_playlist imports it. A podcast episode is source_type podcast, never video or article, and a link on a podcast host (podcasts.apple.com, Spotify, Overcast and the like) is filed as one whatever source_type says. ForeverLM reads an episode from its transcript, which it finds on Apple Podcasts, so content passed for a podcast is not kept: the learner confirms the episode in the app, or find_podcast_match and then resolve_podcast_match confirm it. A URL the learner removed, or a meeting series the learner removed, is not re-added: the result says so (\"Not added: … removed by the learner\"), and only the learner re-adding it in the app brings it back. Pass notebook_id to file the source in a Notebook as well — a Notebook id from list_notebooks (or a Goal id from list_goals) — as adding it from inside that Notebook in the app does; when the url is already in the library, that source joins the Notebook instead. notebook_id is used only as given (never the app's selection, never matched by title), is checked before anything is added, and is refused for ingest-only plugins and for a team's Notebook the learner can only read. The answer's last line, notebook_id_applied, says whether the source is in the Notebook. The source will appear in the app's Studio tab.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "URL or file path of the source"],
                        "title": ["type": "string", "description": "Title of the source"],
                        "source_type": ["type": "string", "enum": ["article", "book", "course", "meeting", "podcast", "video"], "description": "Type of non-paper source"],
                        "content": ["type": "string", "description": "Full text content of the source (optional)"],
                        "parent_group": ["type": "string", "description": "Course/book display title or stable group ID. Required when source_type is course or book. For source_type meeting: the recurring series, matched by meeting-group ID or title (case-insensitive) and created when it does not exist yet."],
                        "author": ["type": "string", "description": "Author name (optional)"],
                        "occurred_at": ["type": "string", "description": "When the meeting took place, ISO 8601 (e.g. 2026-09-02T16:55:00Z). Meetings only; the Meetings tab dates and sorts by it."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook to file the source in as well: a Notebook id from list_notebooks, or a Goal id from list_goals. Omit to add to the library only."],
                    ],
                    "required": ["url", "title", "source_type"],
                ]
            ),
            MCPToolDef(
                name: "add_sources",
                description: "Add several sources in one call (at most \(MCPToolRegistry.maxBatchSourceItems)). Each item takes the same fields as add_source plus update_existing; an item whose url is a page ForeverLM links (a Codex site, Claude artifact, Google Doc or ForeverLM site) is refused per item, naming link_page, as add_source refuses it, and so is a Convoke query result (platform.convoke.bio); items whose canonical URL already exists are reported per item instead of failing the batch, and update_existing refreshes that existing source's content/title/author in place — and, for a meeting, its occurred_at and parent_group, so a re-push corrects the date and series of meetings first pushed without them. Returns a summary line plus one result line per item. Built for user-made plugins pushing a feed — use stable canonical URLs so repeated runs deduplicate, and keep the total payload under ~1 MB. notebook_id files every item that was added, updated or already there in that one Notebook as well (full-scope connections only); the answer's last line, notebook_id_applied, counts how many joined it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sources": [
                            "type": "array",
                            "description": "Items to add, in order. Maximum \(MCPToolRegistry.maxBatchSourceItems) per call.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "url": ["type": "string", "description": "Canonical URL or file path — the dedup key. Keep it stable across runs."],
                                    "title": ["type": "string", "description": "Title of the source"],
                                    "source_type": ["type": "string", "enum": ["article", "book", "course", "meeting", "podcast", "video"], "description": "Type of non-paper source"],
                                    "content": ["type": "string", "description": "Full text content of the source (optional)"],
                                    "parent_group": ["type": "string", "description": "Course/book display title or stable group ID. Required when source_type is course or book. For source_type meeting: the recurring series, matched by meeting-group ID or title (case-insensitive) and created when it does not exist yet."],
                                    "author": ["type": "string", "description": "Author name (optional)"],
                                    "occurred_at": ["type": "string", "description": "When the meeting took place, ISO 8601 (e.g. 2026-09-02T16:55:00Z). Meetings only; omitted, the meeting is dated by when it was added."],
                                    "update_existing": ["type": "boolean", "description": "When the URL already exists, update its content/title/author — and a meeting's occurred_at and parent_group — in place instead of skipping (default false)."],
                                ],
                                "required": ["url", "title", "source_type"],
                            ],
                        ],
                        "notebook_id": ["type": "string", "description": "Optional Notebook for the whole batch: a Notebook id from list_notebooks, or a Goal id from list_goals. Every item added, updated or already present joins it. Not available to ingest-only plugins."],
                    ],
                    "required": ["sources"],
                ]
            ),
            MCPToolDef(
                name: "update_source_content",
                description: "Replace the stored text content (and optionally title/author) of an existing source, matched by source_id or canonical url. Reviews, schedule placements, and other metadata are untouched. Ingest-scoped plugin clients can only update sources they added themselves.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID to update. Provide this or url."],
                        "url": ["type": "string", "description": "Canonical URL of the source to update. Provide this or source_id."],
                        "content": ["type": "string", "description": "New full text content."],
                        "title": ["type": "string", "description": "New title (optional)."],
                        "author": ["type": "string", "description": "New author (optional)."],
                    ],
                    "required": ["content"],
                ]
            ),
            MCPToolDef(
                name: "remove_connector_sources",
                description: "Remove every active source a user-made plugin added, identified by its plugin label (shown on the source rows and in the OAuth consent). Same semantics as remove_source per source: the URL is dismissed so discovery will not re-add it, then the source is archived (undownloaded papers are deleted). Full-scope connections only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "connector_label": ["type": "string", "description": "The plugin label whose sources should be removed."],
                    ],
                    "required": ["connector_label"],
                ]
            ),
            MCPToolDef(
                name: "import_paper_from_url",
                description: "Download an academic paper PDF from a URL, DOI landing page, arXiv/OpenReview page, ScienceDirect page, publisher page, or direct PDF URL; copy the PDF into ForeverLM's synced Papers folder; extract its text; and add it as a paper source, saved at once with its PDF. The Paper Metadata model and Source Content Cleanup then read it in the background, so the answer comes once the PDF is downloaded, with the paper's id and a work_id (list_running_ai_work shows it while it runs; cancel_ai_work stops it and the paper keeps its PDF). Several imports can be sent together: each answers when its PDF is in, and their reading waits its turn. When the work is done the paper carries its title, authors, venue and year and get_source_content returns its text; a failure is saved on the paper, and extract_paper_metadata retries it. ScienceDirect imports use the app's authenticated WebKit session when direct download requires access. When the publisher blocks the PDF (paywall: access denied, login or payment required, an HTML page instead of the file, or no open-access copy anywhere), the paper is still added — as a paywalled paper carrying its bibliography (title, authors, venue, year, DOI) — so tell the user it was added and can be finished by attaching the PDF (attach_pdf_to_paper, or dropping it into the Papers folder) or rechecked later with recheck_paywalled_papers. Only transient failures (network errors, 404) add nothing. Pass notebook_id to file the paper in a Notebook as well (a Notebook id from list_notebooks, or a Goal id from list_goals); a paper the library already holds — by URL or DOI — joins the Notebook instead of being imported again, and the answer's last line, notebook_id_applied, says whether it is in the Notebook.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Paper URL, DOI URL, arXiv/OpenReview page, publisher page, or direct PDF URL. A Slack file's download_url from read_slack_channel is accepted; supply source_url with it."],
                        "source_url": ["type": "string", "description": "Optional stable provenance URL when url is only a download address, such as a Slack file's permalink. Becomes the paper's canonical URL and dedup key; the download address is not stored."],
                        "title": ["type": "string", "description": "Optional title override. If omitted, ForeverLM extracts metadata from the page, PDF, and scholarly APIs."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook to file the paper in as well: a Notebook id from list_notebooks, or a Goal id from list_goals. Checked before the download starts."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "get_connector_inbox",
                description: "Return this ingest plugin's private local staging directory for paper PDFs. Write a downloaded PDF there, then call import_connector_paper with its absolute file path. The directory is plugin-specific and is the only local path import_connector_paper will accept from an ingest-only client.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "import_connector_paper",
                description: "Import one paper for an ingest-only plugin through ForeverLM's complete paper pipeline. Supply either a public academic URL/DOI or a local PDF staged inside the directory returned by get_connector_inbox. The import is deduplicated by canonical URL and DOI, runs the required Paper Metadata and Source Content Cleanup model steps, and stamps the authenticated plugin name as provenance.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Public paper URL, DOI URL, arXiv/OpenReview page, publisher page, or direct PDF URL. Supply this or file_path."],
                        "file_path": ["type": "string", "description": "Absolute path to a PDF inside this plugin's private staging directory. Supply this or url."],
                        "source_url": ["type": "string", "description": "Stable public provenance URL for a staged PDF, such as the Slack file permalink. Used as the paper's canonical URL and dedup key."],
                        "title": ["type": "string", "description": "Optional title hint. The required Paper Metadata model remains authoritative."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "delete_source",
                description: "Permanently delete a source from the knowledge base by ID. For the Studio row's normal Remove behavior, use remove_source instead.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID to delete"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "remove_source",
                description: "Remove a source the same way the Studio context menu does: dismiss its URL so discovery will not re-add it, then archive it (or permanently delete an undownloaded paper).",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID to remove"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "archive_source",
                description: "Archive a source by ID, keeping the source record but removing cached content, embeddings, and Schedule assignments.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID to archive"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "unarchive_source",
                description: "Restore an archived source to active. This also reverses remove_source by clearing the source URL's dismissal, preventing sync or discovery from immediately archiving it again. For sources backed by a local file (book chapters, saved article HTML) this also rebuilds the cached text content that archiving removed, so the source is immediately readable and reviewable again. Does not restore Schedule assignments — re-add to a day with the Schedule tools if needed.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID to unarchive"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "set_visibility",
                description: "Hide or show something in Studio's lists. `target` says what: `source` (one source by `source_id`), `podcast_show` or `youtube_channel` (every episode or video by its show or channel name in `name`), or `course`, `video_playlist` or `meeting` (a group by its course name, playlist id or meeting group name in `name`). A hidden source or group is visual only: it leaves the lists and stays in knowledge for chat, search and reviews. A hidden show or channel is muted: its episodes or videos also leave chat, search and reviews. `force_visible` (target `source` only, instead of `hidden`) brings back one podcast episode or YouTube video whose show or channel is muted, or with false removes that override. Stopping a show's future imports is set_podcast_show_import_blocked.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "enum": ["source", "podcast_show", "youtube_channel", "course", "video_playlist", "meeting"], "description": "What to hide or show."],
                        "source_id": ["type": "string", "description": "The source ID, for target source."],
                        "name": ["type": "string", "description": "Show name, channel name, course name, video-playlist id or meeting group name, as Studio shows it, for every other target."],
                        "hidden": ["type": "boolean", "description": "true to hide, false to show again."],
                        "force_visible": ["type": "boolean", "description": "Target source only: true to show this episode or video while its show or channel is muted, false to remove that override."],
                    ],
                    "required": ["target"],
                ]
            ),
            MCPToolDef(
                name: "set_source_paywall_status",
                description: "Mark an article, paper, or unclassified source as paywalled, or remove its paywalled status. Call this proactively whenever you discover a source is behind a paywall (e.g. fetching it returns a login, subscribe, or purchase page) so the app stops retrying it and shows the paywall recovery options.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "The source ID"],
                        "is_paywalled": ["type": "boolean", "description": "true to mark paywalled, false to clear"],
                    ],
                    "required": ["source_id", "is_paywalled"],
                ]
            ),
            MCPToolDef(
                name: "set_podcast_show_import_blocked",
                description: "Block or unblock a podcast show's future imports by show name — Studio's 'Never Import <show>'. A blocked show's episodes are never imported from Apple Podcasts again, however often they are played; episodes already in the library are untouched (use remove_all_from_podcast for those). This is about ingestion, not visibility: use set_visibility (target podcast_show) to mute a show whose episodes should stay.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "show_name": ["type": "string", "description": "Podcast show name as shown in Studio"],
                        "blocked": ["type": "boolean", "description": "true to stop importing the show, false to import it again"],
                    ],
                    "required": ["show_name", "blocked"],
                ]
            ),
            MCPToolDef(
                name: "attach_text_file_to_source",
                description: "Attach a local text, Markdown, or HTML file to an article/manual source, copying it into ForeverLM's synced Articles folder and storing extracted text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "The source ID"],
                        "file_path": ["type": "string", "description": "Absolute local path to a text, Markdown, or HTML file"],
                    ],
                    "required": ["source_id", "file_path"],
                ]
            ),
            MCPToolDef(
                name: "attach_supplementary_pdf",
                description: "Join a journal's supplementary PDF to a paper that already has its own PDF: the supplement's pages are appended after the article's, so its figures (\"Supplementary Figure 2\", \"Figure S3\", or Extended Data a journal ships separately) join the paper's figure index and inspect_paper_figure, show_source_image, the Reader and search reach them. The article's pages keep their numbers and the paper keeps its metadata: no model runs and nothing is billed. Pass file_path for a PDF on the Mac or pdf_url for the journal's supplementary file. Never pass the article itself or a different paper's PDF; to replace a paper's own PDF use attach_pdf_to_paper. A supplement already joined to the paper is refused.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Paper source ID"],
                        "file_path": ["type": "string", "description": "Absolute local path to the supplementary PDF."],
                        "pdf_url": ["type": "string", "description": "HTTP(S) URL of the supplementary PDF to download and join."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "attach_pdf_to_paper",
                description: "Attach a local PDF file or download a remote PDF URL to a paper source, copying it into ForeverLM's synced Papers folder, extracting text, running AI paper metadata extraction, and clearing paywall/error state. A Slack file's download_url from read_slack_channel is accepted as pdf_url; ForeverLM fetches it as the learner.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Paper source ID"],
                        "file_path": ["type": "string", "description": "Absolute local path to a PDF file. For backward compatibility, an http(s) PDF URL is also accepted."],
                        "pdf_url": ["type": "string", "description": "HTTP(S) PDF URL to download and attach."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "download_papers_needing_attention",
                description: "Bulk-download missing PDFs for paper sources that need one — the MCP equivalent of Studio's 'Try Papers Needing Attention'. Selects papers with no local PDF, an http(s) landing URL, and no paywall marker, resolves the PDF (direct, then open-access fallback), extracts text and metadata, and marks the source ready. Paywall-shaped failures are marked paywalled so they stop being retried; transient failures are left unchanged and reported with source IDs, never faked. Call again to continue past `limit`.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional: restrict to these paper source IDs. If omitted, all papers needing attention are eligible."],
                        "limit": ["type": "integer", "description": "Max papers to process this call (default 25, max 100)."],
                    ],
                    "required": [],
                ]
            ),
            MCPToolDef(
                name: "recheck_paywalled_papers",
                description: "Recheck papers already marked paywalled to see whether a legitimate free PDF is now available. Tries the publisher URL plus DOI-aware PubMed Central, Unpaywall, Crossref, OpenAlex, and preprint fallbacks; validates and attaches any recovered PDF through the normal paper pipeline, then clears paywall state. Papers remain marked paywalled when no readable PDF is recovered. Call again to continue past `limit`.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional: restrict to these paywalled paper source IDs. If omitted, every active paywalled paper without a PDF is eligible."],
                        "limit": ["type": "integer", "description": "Max papers to process this call (default 25, max 100)."],
                    ],
                    "required": [],
                ]
            ),
            MCPToolDef(
                name: "list_paywalled_sources",
                description: "List every source marked paywalled (the papers ForeverLM could not get a readable PDF for) with each one's journal, year and DOI, and a count per journal. It answers \"how many of my paywalled papers are in Nature journals\" and \"which would a subscription unlock\": pass journal to keep one publisher's titles and published_from_year to keep the recent ones. A journal or year that was never recorded is said, never guessed, and with published_from_year a source with no year is listed apart rather than dropped. It reads metadata only. To look again for a free PDF use recheck_paywalled_papers; to set or clear the mark, set_source_paywall_status.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "journal": ["type": "string", "description": "Text the journal's name or the source's link contains, case-insensitive. \"Nature\" keeps Nature, Nature Genetics and the rest, and nature.com links whose journal was never recorded."],
                        "published_from_year": ["type": "integer", "description": "Keep sources published in this year or later (e.g. 2017). A source with no recorded year is listed apart, not left out."],
                        "include_archived": ["type": "boolean", "description": "Also list archived sources (default false)."],
                    ],
                    "required": [],
                ]
            ),
            MCPToolDef(
                name: "rename_group",
                description: "Rename a course, video playlist, or meeting group (sets its display title). group_key is the course name, video-playlist id, or meeting group name.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_type": ["type": "string", "enum": ["course", "video_playlist", "meeting"], "description": "Kind of group."],
                        "group_key": ["type": "string", "description": "Course name, video-playlist id, or meeting group name."],
                        "new_title": ["type": "string", "description": "New display title."],
                    ],
                    "required": ["group_type", "group_key", "new_title"],
                ]
            ),
            MCPToolDef(
                name: "set_connector_auto_import",
                description: "Enable or disable automatic import for the YouTube plugin.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "connector": ["type": "string", "enum": ["youtube"], "description": "Which plugin."],
                        "enabled": ["type": "boolean", "description": "true to auto-import, false to disable."],
                    ],
                    "required": ["connector", "enabled"],
                ]
            ),
            MCPToolDef(
                name: "follow_youtube_liked_videos",
                description: "Make one connected YouTube account's \"Liked videos\" its import source and keep them fresh in the background; each account has its own source. Choose whether to import existing likes or only likes added from now on. Automatic AI transcript formatting is off unless explicitly enabled because a large history can run up a substantial bill on the learner's OpenRouter key. Requires connecting YouTube in Plugins → YouTube.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "account": ["type": "string", "description": "Which connected YouTube account, by channel title or id (get_plugin_connections lists them). Optional when only one is connected."],
                        "import_existing": ["type": "boolean", "description": "true to import existing and future likes; false for future likes only. Defaults to true."],
                        "format_transcripts_automatically": ["type": "boolean", "description": "true to opt into paid AI formatting for automatically fetched liked-video transcripts. Defaults to false; raw transcripts remain available."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "follow_youtube_foreverlm_playlist",
                description: "Make one connected YouTube account's playlist named \"ForeverLM\" its import source and import all of its videos; each account has its own source. The playlist may be public, unlisted, or private. Metadata only; transcripts fetch on demand. Requires connecting YouTube in Plugins → YouTube.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "account": ["type": "string", "description": "Which connected YouTube account, by channel title or id (get_plugin_connections lists them). Optional when only one is connected."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "refresh_youtube_sources",
                description: "Re-check the selected YouTube import source and import any new videos (metadata only), for every connected YouTube account, or for one when account is given.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "account": ["type": "string", "description": "Only this connected YouTube account, by channel title or id. Omit to refresh them all."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "import_youtube_playlist",
                description: "Import a YouTube playlist as a course, exactly as pasting its link in the app does: the course gets a stable ID and the playlist's title, institution and instructors; every video becomes a video source on its own numbered lecture in playlist order; and the transcripts are fetched. The playlist page itself is never saved as a source. This is the one way to ingest a playlist course — do not assemble one by hand with add_source, which refuses a playlist url. A playlist a course already names is imported into that course (missing videos are added, nothing is duplicated); pass course_id to fill a different existing course. Pass notebook_id to make a Notebook follow the course. Takes a minute or more for a long playlist. Returns course_id, lecture and video counts, and how many transcripts arrived.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The playlist address, e.g. https://www.youtube.com/playlist?list=…"],
                        "course_id": ["type": "string", "description": "Optional stable course_id from list_courses to import into. Omit to reuse the course that already names this playlist, or to create a new one."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks that follows the course: its videos join the Notebook, and so does every source the course gains later. A course lives in no Notebook; omit it and no Notebook follows it. Checked before anything is imported."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "import_teachable_course",
                description: "Import a Teachable course from any one of its lecture links (…/courses/<course>/lectures/<id>, on *.teachable.com or a school's own domain). ForeverLM reads the course outline from the lecture page as the learner signed in inside ForeverLM, makes the course (or reuses the one with the same title), and files every lecture that has a video as a video source on its own numbered lecture in the school's order; lectures with only text are skipped. Each video's transcript is its audio, downloaded and transcribed with speech-to-text, headed by the lecture's own text (talk title, speakers). The call returns once the lectures are filed; transcripts finish in the background, a few minutes per lecture, and each video source shows its progress or the reason it failed. The learner must be signed in to the school in ForeverLM's browser (Library profile) — a sign-in made in their own web browser does not count; the error says so when it is missing. Pass notebook_id to make a Notebook follow the course. Returns course_id and the lecture count. The result's work_id is the background transcription: cancel_ai_work stops the lectures not yet transcribed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "A lecture address from the course, e.g. https://school.teachable.com/courses/<course>/lectures/123"],
                        "course_id": ["type": "string", "description": "Optional stable course_id from list_courses to import into. Omit to reuse the course with the same title, or to create a new one."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks that follows the course: its videos join the Notebook, and so does every source the course gains later. A course lives in no Notebook; omit it and no Notebook follows it. Checked before anything is imported."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "import_gemini_notebook",
                description: "Import a Gemini Notebook (NotebookLM until July 2026) from its address, notebook.google.com/notebook/<id>, into ForeverLM as a Notebook, the way pasting the link into the source bar does. ForeverLM reads the notebook as the learner signed in to Google inside ForeverLM and files: each source (a web page or YouTube video through the ordinary link route, so the app reads it and a paper gets its PDF; a Google Doc linked in Docs; pasted text, an uploaded file or a PDF as an article holding the notebook's text word for word), each chat as a chat under the Notebook linked to those sources and drawn on the day's log (the Activity pane) at the hours it ran (a chat, not a review: its sources are not marked reviewed), and each note and written report as a Doc in the Notebook. Audio and video overviews, flashcards, quizzes, mind maps and apps stay in the notebook and are listed in left_in_notebook. The Notebook is the one named by notebook_id, else the Notebook already titled like the notebook, else a new one. Importing again adds only what is new: sources are matched by address, a chat by its conversation (and brought level with it), a Doc by its title in the Notebook, and no Doc is overwritten. The learner must be signed in to Google in ForeverLM's browser (Library profile) — a sign-in made in their own web browser does not count; the error says so when it is missing. Returns notebook_id, the source, chat and Doc ids, and anything that could not be filed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The notebook's address, e.g. https://notebook.google.com/notebook/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d (a notebooklm.google.com address works too)."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook (from list_notebooks) to file the notebook under. Omit to reuse the Notebook titled like the notebook, or to create one."],
                    ],
                    "required": ["url"],
                ]
            ),
            MCPToolDef(
                name: "import_video_overview",
                description: "Bring a video overview into a Notebook: a Gemini Notebook video overview downloaded as an MP4, or any MP4, M4V or MOV on the learner's Mac. The file is copied into the library as a video source, its poster drawn from the film, and filed in the Notebook, where its Studio lists it as a Video overview and the Reader plays it. Importing the same file again finds the video it already made rather than a copy. file_path must be inside the ForeverLM library or the Desktop, Documents or Downloads folder. Nothing is spent. The video has no transcript.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": ["type": "string", "description": "Absolute local path to an MP4, M4V or MOV file."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook (from list_notebooks) to file the video in. Omit to add it to the library only. Checked before anything is copied; a Notebook that is archived or a team's the learner can only read is refused."],
                    ],
                    "required": ["file_path"],
                ]
            ),
            MCPToolDef(
                name: "create_course",
                description: "Create a new empty course with a stable ID. Call list_courses first; this tool refuses a duplicate normalized display title. Pass notebook_id to make a Notebook follow it: the sources its lectures gain join that Notebook. The course itself lives in no Notebook.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Course display title."],
                        "course_code": ["type": "string", "description": "Optional course code, e.g. CS336."],
                        "institution": ["type": "string", "description": "Optional institution, e.g. Stanford."],
                        "instructors": ["type": "string", "description": "Optional instructor names."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks that follows the new course. Omit it and no Notebook follows it."],
                    ],
                    "required": ["title"],
                ]
            ),
        ]
    }
}
