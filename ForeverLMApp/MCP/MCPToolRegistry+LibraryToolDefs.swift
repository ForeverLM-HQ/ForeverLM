// MCPToolRegistry: the library tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var libraryToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_mcp_status",
                description: "Check whether the ForeverLM MCP server is active and ready to receive tool calls. Call this before other ForeverLM tools. From the Mac, icloud_account says which iCloud account its library syncs with (syncs_with_icloud, environment, and user_record_name, the account's container-scoped CloudKit user record name, the same kind of id list_teams gives for members, once CloudKit has answered); ForeverLM on the web uses it to ask only a Mac on the learner's own account. answered_by says which Mac answered, since another Mac signed in to the same account can hold the connection: app and build, device_id (that Mac's ForeverLM sync id), model, and computer_name, which is left out while its answers are narrowed. narrowed, when present, says that Mac lists only part of the library for now: when what the learner names is not listed, say you cannot see it from that Mac rather than choosing the closest match.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "report_connector_status",
                description: "Report this ingest plugin's current upstream sync health. Call at the start and end of every scheduled run, including runs with no new sources, and report needs_reconnect when upstream authorization is invalid.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "state": [
                            "type": "string",
                            "enum": ["healthy", "syncing", "needs_reconnect", "error"],
                            "description": "Current operational state of this plugin's upstream sync.",
                        ],
                        "detail": [
                            "type": "string",
                            "description": "Optional concise user-actionable detail. Do not include credentials or source content.",
                        ],
                    ],
                    "required": ["state"],
                ]
            ),
            MCPToolDef(
                name: "get_sync_status",
                description: "Check iCloud sync health for this Mac: what sync is doing now and why it waits or stopped (iCloud being full among the reasons), how many local changes are still waiting to upload, when it last synced, the container environment, whether iCloud is signed in, and in `icloud_storage` how much of the learner's iCloud ForeverLM's PDFs, text, other files and iCloud Drive files take up. `migration` reports the library's move to the new iCloud store: whether the library has moved and how this Mac joined, the seed's progress and the Mac moving it, why uploads pause, whether this Mac is offered This Mac holds my library, and the bytes each owned space holds. Use this when the learner reports missing or stale items across devices, before concluding anything is lost. answered_by names the Mac that answered, as in get_mcp_status, and narrowed, when present, says its listings show only part of the library for now.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "list_sources",
                description: "Inventory the ENTIRE knowledge base (articles, papers, podcasts, books, videos). Use only when the learner explicitly asks to browse or list the whole library. Never use this for a targeted title, author, paper, keyword, or topic lookup, and never use it as a fallback after search_sources_semantic; for a complete list of one show's episodes, one author's papers, or every title containing a name, use filter_sources; refine that search or inspect a promising candidate with get_source_content instead. This result can be very large. Book chapters are grouped under their book. Returns metadata only, not full content. To list one explicitly requested Notebook's sources, resolve its ID with list_notebooks and pass it to list_notebook_sources.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "list_courses",
                description: "List every course with its stable course_id, display title, metadata, lecture count, grouped-source count, lecture-item count, and the Notebooks that follow it (followed_by_notebook_ids; a course lives in no Notebook). Pass notebook_id to list only the courses that Notebook follows. Always call this before creating a course or adding course materials so an existing course is reused instead of duplicated.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks: only the courses that Notebook follows."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_course",
                description: "Inspect one course's metadata, the Notebooks that follow it (followed_by; a course lives in no Notebook), lecture IDs, lecture-item IDs, attached sources, and unassigned course sources. Pass the stable course_id from list_courses; a unique exact display title is also accepted.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from list_courses (preferred), or a unique exact course display title."],
                    ],
                    "required": ["course_id"],
                ]
            ),
            MCPToolDef(
                name: "get_lecture_papers",
                description: "Get every paper source associated with one course lecture, including source IDs, lecture-item IDs, bibliographic metadata, and availability state. Use get_source_content with a returned source_id to read a paper.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "lecture_id": ["type": "string", "description": "Lecture ID returned by get_course."],
                    ],
                    "required": ["lecture_id"],
                ]
            ),
            MCPToolDef(
                name: "get_source_content",
                description: "Get the full text content of a specific source by ID. When canonical stored text is available, the response includes its SHA-256 revision so a pre-generated review guide can be saved safely with save_source_review_guide.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "inspect_paper_figure",
                description: "See a figure from a paper in the learner's library. Returns the figure itself as an image, rendered from the paper's own PDF on the learner's Mac and cropped to the figure, together with its caption and — when ForeverLM's vision analysis is available — an explanation, the visible evidence and each labelled panel's reading. Use it when the learner asks what a figure, graph, diagram or labelled subfigure shows, or a question needs the plot rather than the prose: get_source_content ends in the captions, not the pictures. Use the paper's source_id from list_sources or a search and the printed label, for example Figure 2, Fig. 3 or Extended Data Fig. 1. Pass panel_label to zoom in on one subfigure: the returned image is then cropped to that panel alone and the explanation is that panel's, so going through a figure panel by panel is one call per panel. A paper in the library is shown from its own PDF. The first inspection of a figure runs a vision model over it and is billed to the learner's own OpenRouter key; later calls answer from the stored analysis. The result also carries a Markdown line (foreverlm://image/…) that renders the picture inside ForeverLM — include it verbatim in a review transcript or Doc, not in an answer shown only in this client. Needs the learner's Mac open and connected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Paper source ID, from list_sources or a search result."],
                        "figure_label": ["type": "string", "description": "Printed figure label, for example Figure 2 or Extended Data Fig. 1."],
                        "panel_label": ["type": "string", "description": "Optional subfigure label, for example b or A. When given, the image is cropped to that panel alone and the explanation is that panel's."],
                    ] as [String: Any],
                    "required": ["source_id", "figure_label"],
                ]
            ),
            MCPToolDef(
                name: "show_source_image",
                description: "See a picture from a source in the learner's library, returned as an image rendered on the learner's Mac: a figure, diagram, photo or illustration from a paper, a book chapter or an article, or a slide from a video or meeting recording. Pass query with the printed figure label (Figure 3-4) or caption words to find one picture; pass page for a PDF page an earlier listing named, never a guessed number; pass neither to list the source's captioned pictures. Only pages that actually carry a picture are shown, so a page of prose and a paper's title page are refused: list the pictures first when you do not know which page holds the one you mean. A paper's figures come back cropped to the figure. Up to four matching pictures are attached as images, in the order listed; a longer listing is text only, and a second call with query or page narrows it to the picture wanted. For a video or recording the pictures are its captured slides, each listed with the stretch of the talk it was on screen for and the words spoken meanwhile: pass query with words from the slide or what was said over it, or slide with a number from an earlier listing; a video whose slides were never captured is refused and names extract_video_slides, which captures them. To see any moment of a video, slide or not, pass at with the time: the frame on screen then is captured from the video and attached, and crop zooms in on part of it or of a slide. Each entry also carries a Markdown line (foreverlm://image/…) that renders the picture inside ForeverLM — include it verbatim in a review transcript or Doc, not in an answer shown only in this client. Call it whenever the learner asks to see, show or display a figure, picture or slide, or asks what one looks like; for a paper figure with an explanation, prefer inspect_paper_figure. Needs the learner's Mac open and connected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID from list_sources or a search result."],
                        "query": ["type": "string", "description": "Figure label or caption words to match, for example Figure 3-4 or lactate dehydrogenase."],
                        "page": ["type": "integer", "minimum": 1, "description": "PDF sources only: show this one-based page."] as [String: Any],
                        "slide": ["type": "integer", "minimum": 1, "description": "Video and recording sources only: show this slide, by the number an earlier listing gave it."] as [String: Any],
                        "at": ["type": "string", "description": "Video and recording sources only: capture and show the frame on screen at this time — seconds (265) or a clock reading (4:25, 1:02:03). Any moment works, not only captured slides: use it for a diagram being drawn, an animation, or a time the transcript names."] as [String: Any],
                        "crop": [
                            "type": "object",
                            "description": "Zoom in on part of one slide or frame: fractions of the picture from its top-left corner, each between 0 and 1. Look at the uncropped picture first, then crop to the part that matters.",
                            "properties": [
                                "x": ["type": "number"],
                                "y": ["type": "number"],
                                "width": ["type": "number"],
                                "height": ["type": "number"],
                            ] as [String: Any],
                            "required": ["x", "y", "width", "height"],
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "save_source_review_guide",
                description: "Save a pre-generated Source Review Guide for one source. First call get_source_content, generate a concise source-grounded guide with KEY IDEAS, REVIEW QUESTIONS AND ANSWER GUIDES (Question, Strong answer, Probe), and CONNECTION QUESTION, then pass the returned content_sha256 unchanged. The guide is bound to that exact canonical source revision, replaces any older guide, clears a pending preparation request, and syncs to the learner's other devices.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID from get_source_content or a Schedule tool."],
                        "content_sha256": ["type": "string", "description": "Exact content_sha256 returned by get_source_content. The save fails if the source changed after the guide was generated."],
                        "guide": ["type": "string", "description": "Source-grounded plain-text review guide. Use the Source Review Guide sections described above; do not include a review-session transcript or learner score."],
                    ],
                    "required": ["source_id", "content_sha256", "guide"],
                ]
            ),
            MCPToolDef(
                name: "list_source_actions",
                description: "List durable actions available for a source, matching the source row context menu where possible. UI-only actions such as opening Finder, Safari, or file pickers are reported as unavailable to MCP.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "list_source_highlights",
                description: "List the passages the learner highlighted in one source, with the note they wrote on each. These are the learner's own marks, made while reading in ForeverLM — the clearest record of what they found important in a source. Read them before reviewing or summarizing a source the learner has already read. A mark's publication_update is what has been learned since the source was written, as research put it (not the learner's words), and a mark with a session_id carries the chat that research came from.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "search_source_highlights",
                description: "Search every highlight and reader note in the library, newest first. Use it to answer what the learner has been marking lately or what they noted about a topic, when the source is not known yet. Omit query to list the most recent marks. Pass color to see one kind of mark across the whole library: blue marks are what the learner set aside to follow up, pink what they doubt.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Optional text to match against the highlighted passage, the learner's note, or the mark's since-publication update."],
                        "color": ["type": "string", "description": "Optional marker color to keep: \(SourceHighlightColor.meaningGuide)."],
                        "limit": ["type": "integer", "description": "Maximum highlights to return. Defaults to 50, capped at 200."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_source_highlight",
                description: "Highlight a passage or a picture in a source and optionally write a note on it, exactly as pressing Highlight in ForeverLM's reader would. Quote the passage verbatim from get_source_content: the passage is located in the stored text and the mark is anchored to the source's own wording, so it paints in the reader and syncs to the learner's other devices. A passage that is not found, or that is already marked, is refused rather than guessed at. To mark a figure or image of a web page instead, pass image_url (the picture's URL as the page serves it) with no quote; the reader outlines that picture. To attach research to the passage it updates — what has been published since a textbook or paper was written — save that research with import_review_chat (mark_reviewed false), then mark the passage (a section heading works) in blue with the short version as publication_update (never as note, which is the learner's), each paper it names in references, and the chat's id as session_id: the reader shows the update under a Since publication heading, and opens that chat, and each paper, from the mark.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "The source ID"],
                        "quote": ["type": "string", "description": "The passage to mark, copied verbatim from the source text returned by get_source_content. Omit when marking a picture by image_url."],
                        "image_url": ["type": "string", "description": "The absolute http(s) URL of a picture in the page to mark, as the page serves it. Pass it without a quote to mark the picture alone, or with one to mark both."],
                        "image_alt": ["type": "string", "description": "The picture's alt text, if the page gives one; it names the mark in the notes list."],
                        "note": ["type": "string", "description": "Optional note about the passage or picture: the learner's own thinking, or what they ask you to note. Research goes in publication_update. Omit for a bare highlight."],
                        "publication_update": ["type": "string", "description": "Optional: what has been learned since the source was written. First line a one-sentence headline of what changed; then, on the next line, two to four plain-text sentences naming each paper as (Author et al., Journal Year), the way its references entry's citation reads. No markdown or links."],
                        "color": ["type": "string", "description": "Marker color, chosen by what the mark means to the learner: \(SourceHighlightColor.meaningGuide). Defaults to yellow."],
                        "session_id": ["type": "string", "description": "Optional: the saved ForeverLM review this note came from, by the id import_review_chat or get_review_sessions gives (a foreverlm://chat/<id> link works too). The reader opens it from the mark. From a chat inside ForeverLM, leave it out: the mark links to that chat."],
                        "references": [
                            "type": "array",
                            "description": "Optional: the papers or pages the update (or note) cites, in the order it names them, at most 20. The reader lists them on the mark with Add to Library, or Open when the library holds one.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "citation": ["type": "string", "description": "How the note names it, such as \"Vozza et al., PNAS 2014\"."],
                                    "doi": ["type": "string", "description": "The paper's DOI, such as 10.1073/pnas.1320692111."],
                                    "url": ["type": "string", "description": "The paper's or page's address, for one without a DOI."],
                                    "title": ["type": "string", "description": "The paper's title, if known."],
                                ],
                                "required": ["citation"],
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "update_source_highlight",
                description: "Rewrite the note or the since-publication update, change the color, link the chat the update came from, or set the papers it cites on an existing highlight. Pass an empty note to turn it back into a bare highlight. The passage itself is not editable — mark a different passage with create_source_highlight instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "highlight_id": ["type": "string", "description": "Highlight ID from list_source_highlights or search_source_highlights."],
                        "note": ["type": "string", "description": "New note text, in the learner's own words. An empty string clears the note and leaves a bare highlight."],
                        "publication_update": ["type": "string", "description": "What has been learned since the source was written, shaped as in create_source_highlight, replacing the update the mark has. An empty string clears it."],
                        "color": ["type": "string", "description": "New marker color, by what the mark means: \(SourceHighlightColor.meaningGuide)."],
                        "session_id": ["type": "string", "description": "The chat the note came from, by its id from import_review_chat or get_review_sessions (or a foreverlm://chat/<id> link); the reader opens it from the mark. An empty string unlinks it."],
                        "references": [
                            "type": "array",
                            "description": "The papers or pages the update (or note) cites, replacing the list; an empty array clears it. At most 20, each shaped as in create_source_highlight.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "citation": ["type": "string", "description": "How the note names it, such as \"Vozza et al., PNAS 2014\"."],
                                    "doi": ["type": "string", "description": "The paper's DOI, such as 10.1073/pnas.1320692111."],
                                    "url": ["type": "string", "description": "The paper's or page's address, for one without a DOI."],
                                    "title": ["type": "string", "description": "The paper's title, if known."],
                                ],
                                "required": ["citation"],
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                    "required": ["highlight_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_source_highlight",
                description: "Remove a highlight and its note from a source. The learner made these marks by hand while reading, so only delete one when they ask for it by name.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "highlight_id": ["type": "string", "description": "Highlight ID from list_source_highlights or search_source_highlights."],
                    ],
                    "required": ["highlight_id"],
                ]
            ),
            MCPToolDef(
                name: "list_meeting_groups",
                description: "List recurring meeting groups as JSON with stable group_id values, session counts, and the sidebar image each folder has been given.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "get_meeting_group",
                description: "Get one recurring meeting group as JSON with session source IDs, artifact metadata, and its sidebar image. Pass group_id from list_meeting_groups.",
                inputSchema: [
                    "type": "object",
                    "properties": ["group_id": ["type": "string", "description": "Meeting group ID"]],
                    "required": ["group_id"],
                ]
            ),
            MCPToolDef(
                name: "set_meeting_schedule",
                description: "Set or clear when a recurring meeting series meets — what \"Schedule…\" in the meetings context menu does. A series with a schedule has each session's action items read out of its transcript as it lands (list_meeting_action_items). Pass group_id from list_meeting_groups; weekdays as 1 (Sunday) to 7 (Saturday); start as 24-hour HH:MM in the given IANA time zone; duration in minutes. Pass clear true to remove the schedule.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "Meeting group ID from list_meeting_groups."],
                        "weekdays": ["type": "array", "items": ["type": "integer"], "description": "1 = Sunday … 7 = Saturday. Weekdays are [2,3,4,5,6]."],
                        "start": ["type": "string", "description": "24-hour HH:MM in the time zone given."],
                        "duration_minutes": ["type": "integer", "description": "How long the meeting is; at least 5."],
                        "timezone": ["type": "string", "description": "IANA zone the clock is read in, e.g. America/Los_Angeles."],
                        "clear": ["type": "boolean", "description": "true removes the schedule."],
                    ],
                    "required": ["group_id"],
                ]
            ),
            MCPToolDef(
                name: "list_meeting_action_items",
                description: "The action items ForeverLM read out of a meeting series' session transcripts: what each session asked someone to do, with owner and due hint when the transcript named them, and whether the learner ticked it off. Pass group_id from list_meeting_groups, or source_id for one session. latest_only true returns just the most recent session's items, open first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "Meeting group ID from list_meeting_groups."],
                        "source_id": ["type": "string", "description": "One session's source ID instead of the whole series."],
                        "latest_only": ["type": "boolean", "description": "Only the most recent session's items, open first."],
                    ],
                    "required": [],
                ]
            ),
            MCPToolDef(
                name: "set_meeting_action_item_done",
                description: "Tick a meeting action item off, or reopen it. Pass item_id from list_meeting_action_items.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_id": ["type": "string", "description": "Action item ID."],
                        "done": ["type": "boolean", "description": "true marks it done (the default); false reopens it."],
                    ],
                    "required": ["item_id"],
                ]
            ),
            MCPToolDef(
                name: "set_meeting_folder_image",
                description: "Give one meeting folder its own image in ForeverLM's sidebar, exactly as \"Set Folder Image…\" in the meetings context menu does — the group's own logo in place of the shared meetings icon. Pass group_id from list_meeting_groups. A web address follows the learner's account to their other devices; a path to a file on this Mac only renders on this Mac. The image is drawn to fill a small square tile, so prefer a square logo over a wide wordmark or a photo. Omit image_url to clear the choice and go back to the default icon.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "Meeting group ID from list_meeting_groups."],
                        "image_url": ["type": "string", "description": "An http(s) address of an image, or an absolute path to one on this Mac. Omit, or pass an empty string, to restore the default meetings icon."],
                    ],
                    "required": ["group_id"],
                ]
            ),
            MCPToolDef(
                name: "get_source_settings",
                description: "Read Settings › Sources: for every source family (articles, papers, books, courses, meetings, podcasts, youtube, x) whether it takes part in search and AI — chat, semantic and keyword search, reviews and the MCP library tools — and whether its tab is pinned to the Studio tab bar, in the learner's tab order. This is the per-family knowledge boundary; hiding a single source is visual only and is not part of it.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_source_settings",
                description: "Change Settings › Sources for one source family, exactly as flipping its switches in the pane does. include_in_search_and_ai decides whether the family is part of what chat, search, reviews and the MCP library tools may draw on — false keeps a whole family away from the AI while its sources stay in the library and its tab stays pinnable. pinned puts the family's tab on the Studio tab bar or takes it off; the bar keeps at least one pinned family, so unpinning the last one is refused. Pass one switch or both. The choice follows the learner's account to their other devices.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "family": ["type": "string", "enum": MCPDataStore.sourceFamilyIDs, "description": "The source family, as get_source_settings lists it."],
                        "include_in_search_and_ai": ["type": "boolean", "description": "true: the family takes part in search, chat, reviews and the MCP library tools. false: it is left out of all of them."],
                        "pinned": ["type": "boolean", "description": "true: the family's tab is on the Studio tab bar. false: it is taken off the bar; refused for the last pinned family."],
                    ],
                    "required": ["family"],
                ]
            ),
            MCPToolDef(
                name: "list_unconverted_zoom_recordings",
                description: "The Zoom recordings on the learner's Mac that only Zoom can convert — what the Meetings tab and Settings › Sources › Zoom Transcripts list. Zoom records a local meeting as raw double_click_to_convert_*.zoom files and converts them when the meeting ends; a meeting ended before that, or with Zoom quit, leaves the raw files, and ForeverLM cannot read them. Each entry carries folder_path (the key for resolve_unconverted_zoom_recording), title (the series' title when one matches the folder, else Zoom's file-safe spelling), started_at, last_written_at, raw_bytes and ignored. A recording written in the last fifteen minutes is left out: Zoom may still be converting it. converts_automatically says whether ForeverLM may use Accessibility on this Mac; when it may, ForeverLM hands waiting recordings to Zoom by itself, one at a time and at most twice each, and answers Zoom's unknown-source dialog, so a recording still listed is one Zoom could not convert. Device-local: the answer is this Mac's folder.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "resolve_unconverted_zoom_recording",
                description: "Say what to do with one Zoom recording from list_unconverted_zoom_recordings, exactly as the row's buttons do. action convert opens the raw file in Zoom on the learner's Mac — the double-click Zoom names the file after; Zoom asks \"Files from unknown sources\" there, ForeverLM presses Convert Anyway itself when it may use Accessibility (answers_zoom) and the learner answers otherwise, and ForeverLM then files the recording as a session of its series and transcribes it. action ignore leaves the recording in the folder, takes it off the Meetings tab and never files it — for a meeting that did not happen; unignore takes that back. Ask the learner before converting a recording they did not mention: conversion is visible on their screen and the transcription that follows is billed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "folder_path": ["type": "string", "description": "folder_path from list_unconverted_zoom_recordings."],
                        "action": ["type": "string", "enum": ["convert", "ignore", "unignore"], "description": "convert opens it in Zoom; ignore hides it and never files it; unignore lists it again."],
                    ],
                    "required": ["folder_path", "action"],
                ]
            ),
            MCPToolDef(
                name: "get_day_settings",
                description: "Read Settings › Chat › Day: the hours the learner's day runs (day_start_hour, day_end_hour; 6 and 24 unless the learner set them) — what get_calendar_events counts free time inside and the hours the Activity pane's clock draws; this pair follows the account to the learner's other Macs — and whether this Mac asks \"Plan your day?\" (suggest_planning_the_day, device-local, on unless switched off: each morning today's calendar holds nothing the learner planned — meetings with other people and recurring events do not count — from the start of their day until the afternoon hour /plan turns to tomorrow, with suggest_planning_scope giving this Mac's hours, a card in the bottom-left of the Studio window asks and waits until answered, and a notification says it once if the learner sits down with ForeverLM not in front; force_planning_the_day, device-local and off unless switched on, makes the question unavoidable while it stands: the planning chat opens by itself the first time the learner is at the Mac, and the card cannot be closed until the calendar holds a plan). notifications_status is whether macOS lets ForeverLM notify on this Mac at all (allowed, refused or not_asked), which a bout's alarms, the memory review reminder and \"Plan your day?\" as a notification need; refused means none of them reaches the learner while the switches still read as on, and only the learner can undo it, in System Settings › Notifications. notifications_note says what the status means. nudge_back_on_track (device-local, off unless switched on) is Nudge Me Back on Track: while a learning bout runs, or a timed calendar block naming nobody else is on, ForeverLM reads what is in front on this Mac — the app, its window's title and a browser's page address, through Accessibility, never the screen's pixels — and Apple Intelligence on the Mac judges it against the goal; after two minutes off track one notification names the goal, and the drift goes on the day's log as off_track spans (get_day_activity). nudge_status says whether it is running: off, waiting_for_a_goal, watching, needs_accessibility (only the learner can grant it, in System Settings › Privacy & Security › Accessibility) or apple_intelligence_unavailable; nudge_note says it in a line. read_screen (device-local, off unless switched on) is Read the Window Too: the judge also reads the words in the window in front, captured once per new window, recognised on the Mac and kept nowhere (never a password manager's); read_screen_status is off, reading, or needs_screen_recording (only the learner can grant it, in System Settings › Privacy & Security › Screen & System Audio Recording; until then windows are judged by their titles alone).",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_day_settings",
                description: "Change Settings › Chat › Day, exactly as the pane does; pass any of the six settings, or request_notifications. day_start_hour and day_end_hour set the hours the learner's day runs (the start 0–23, the end 1–24 with 24 midnight, the end after the start); they follow the account to the learner's other Macs. suggest_planning_the_day false: this Mac stops asking \"Plan your day?\" on a morning with nothing planned; true (the default) resumes. force_planning_the_day true makes the learner plan: on a morning with nothing planned the planning chat opens by itself the first time they are at the Mac, and the \"Plan your day\" card cannot be closed, tucked or switched off from itself; only a plan in the Mac's Calendar, or this setting set false, ends it. It does nothing while suggest_planning_the_day is false; false (the default) leaves the question a card they can close. request_notifications true presses the pane's Allow Notifications: if macOS has never asked on this Mac, it shows its prompt there, and only the learner can answer it, so tell them to look for it; the call does not wait for the answer, and notifications_request says what happened. On a Mac that refused, nothing is shown: only the learner can allow ForeverLM again, in System Settings › Notifications. nudge_back_on_track true turns on Nudge Me Back on Track on this Mac (get_day_settings says what it does) and shows macOS's Accessibility prompt there, which only the learner can answer; false turns it off. read_screen true lets it read the words in the window in front as well, and shows macOS's Screen Recording prompt once; false: titles only. Returns the settings, notifications_status, nudge_status and read_screen_status among them, and changed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "day_start_hour": ["type": "integer", "minimum": 0, "maximum": 23, "description": "The hour the learner's day starts, 0 (midnight) to 23. 6 unless set."],
                        "day_end_hour": ["type": "integer", "minimum": 1, "maximum": 24, "description": "The hour the learner's day ends, 1 to 24 (midnight), after day_start_hour. 24 unless set."],
                        "suggest_planning_the_day": ["type": "boolean", "description": "true (the default): each morning today's calendar holds nothing the learner planned, ask \"Plan your day?\" with a card in the Studio window that waits until answered, and a notification once if ForeverLM is not in front. false: never."],
                        "force_planning_the_day": ["type": "boolean", "description": "true: make the learner plan. While the morning's calendar holds nothing they planned, the planning chat opens by itself the first time they are at the Mac and the card cannot be closed until a plan is in the calendar. false (the default): the card can be closed. No effect while suggest_planning_the_day is false."],
                        "request_notifications": ["type": "boolean", "description": "true: ask macOS to let ForeverLM notify on this Mac, as Allow Notifications in Settings › Background › Memory review does. Only a Mac never asked shows the prompt, and only the learner can answer it."],
                        "nudge_back_on_track": ["type": "boolean", "description": "true: during a bout or a calendar block of the learner's own, notice drift to unrelated apps and sites on this Mac (Apple Intelligence, on the Mac), nudge once after two minutes and log it; asks macOS for Accessibility. false (the default): off."],
                        "read_screen": ["type": "boolean", "description": "true: Nudge Me Back on Track also reads the words in the window in front, on the Mac, kept nowhere; asks macOS for Screen Recording. false (the default): window titles and page addresses only."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_own_router_key",
                description: "Read AI Usage › API keys: whether the learner has stored their own OpenRouter key, which router it is for, and the key's last four characters. Never the key itself. ForeverLM's AI features are bring your own key: with a key stored, OpenRouter bills the learner directly, at cost, for everything ForeverLM sends through it, and ForeverLM adds nothing. OpenRouter is the only supported provider. The key runs while the account is unlocked (its free days, or ForeverLM paid for; own_key_allowed); a locked account's key runs no model, free ones included. The response names the scope: an OpenRouter key covers chat, reviews and background tasks plus every voice, speech-to-text, image and video model OpenRouter serves, first-party ones such as Gemini and Grok speech, GPT-4o mini transcription and Veo included, so the key pays for every model ForeverLM uses.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_own_router_key",
                description: "Store, replace, or remove the learner's own OpenRouter key — AI Usage › API keys, exactly as pasting it into the pane does. Pass router and key to store or replace; pass clear: true (with router) to remove. The key goes to the learner's iCloud Keychain, never to a synced preference, a log, or the response; the response carries only the router and the key's last four characters. Ask before calling this with a key the learner did not just hand you.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "router": ["type": "string", "enum": ManagedAI.OwnKeyRouter.allCases.map(\.rawValue), "description": "openrouter — the router the key belongs to."],
                        "key": ["type": "string", "description": "The API key to store. Omit when clearing."],
                        "clear": ["type": "boolean", "description": "true removes the stored key; the AI features it was paying for stop until a key is stored again, apart from any leftover balance, which pays until it runs out."],
                    ],
                    "required": ["router"],
                ]
            ),
            MCPToolDef(
                name: "get_ai_usage_report",
                description: "Read the AI usage ledger behind AI Usage › Activity for a period (days back, default 30, or from/to as local YYYY-MM-DD): total spend, spend by task with the models each task ran and per-call averages (tokens in and out, cache read share, cost per call), spend by model with its catalogue price, spend by day, and beside every configurable task the route it would run on now (provider, model, effort, speed, which default it follows or that it is overridden) with that model's price per million tokens. cost_usd is what the provider billed when it reported an amount, else the list-price estimate stamped at record time; calls that could not be priced are counted in unpriced_calls and never folded into a total, and a model whose price is unknown says price_known false rather than a guess. Reads no source content.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "description": "How many days back from now to report. Default 30. Not with from/to."],
                        "from": ["type": "string", "description": "First local calendar day of the period, YYYY-MM-DD."],
                        "to": ["type": "string", "description": "Last local calendar day of the period, inclusive, YYYY-MM-DD. Defaults to today when from is given."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_ai_task_settings",
                description: "Read Settings › AI Models: the Default Model that chat and its companions follow, docs (the model Edit with AI in a Doc runs on; follows_default_model while Docs have none of their own), the text-only and multimodal Background models, every background task with the model it runs on and which it follows (background_text, background_multimodal, or task_model when the learner gave it a model of its own; a meeting task says kept_off_free_model while it runs on a paid model because its Background model is free, and waiting_for_paid_model when it has none to run on), meetings_may_use_free (Setup's Meetings answer), the catalogue every picker offers, grouped by maker with each model's price per million input, output, cached-input and cache-write tokens from the app's one pricing table, whether it can read images, its effort options, whether it is selectable, and qualification: for chat, background and background_images, whether the model passed a test run of that work (passed, failed with OpenRouter's words, or untested; a model is tested the first time it is picked for a role and applied only if it passes; one that failed stays in the catalogue and is tested again when picked, and set_ai_task_settings tests an untested or previously failed pick first and refuses one that fails), and free_models: OpenRouter's free models that can run text work and work that reads images and have not failed a test run of it, best first, with free_model_blocker saying why none can run when that is so. accepts lists exactly what set_ai_task_settings takes.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "set_ai_task_settings",
                description: "Change Settings › AI Models exactly as the pane's own controls do. target default_model sets the Default Model card (provider + model); docs sets the model Edit with AI in a Doc runs on, as the ForeverLM mark on the Edit with AI panel does (provider + model), and docs with neither goes back to following the Default Model; background_text and background_multimodal set Settings › Background's Text-only and Multimodal models, which every background task runs on unless it has a model of its own; task_model (task_id plus provider and model, or neither to go back to following) gives one task a model of its own, as its page under Background › Tasks does, and takes only a vision model for a task with requires_vision. Every selection must be a catalogue model on an offered provider, not retired — or a model from free_models for background_text or background_multimodal (reads_images for the latter), which moves only that setting and costs nothing, though its providers may keep and train on what is sent and it is often busy; background_multimodal takes only a vision model. target meetings records Setup's Meetings answer (meetings_may_use_free): false, the default, keeps meeting tasks on a paid model while their Background model is free (its first paid backup; with none the task waits, and ForeverLM picks no paid model for them); true lets them use the free one. Ask it before moving background_text to a free model. target data_privacy flips Settings › Data & Privacy's “Don't show models that train on my data” (hide_training_models): true leaves every model marked trains_on_inputs out of the pickers and the catalogue, false offers them again, labelled. target host chooses which of a model's OpenRouter hosts runs chat or a Background model's work (host_for, host, host_fallback), and whether only its hosts in the US may (host_region), as a chosen model card's ⋯ in Settings › Chat does. target backups sets the backup models chat's scheduled runs or a Background model moves its work to, in order, when its model is busy, fails or sends back nothing usable (backups_for, backups), as Use as Backup on a model card does; each backup is billed at its own price. Ask before calling this: it changes which model, and so which price, the learner's work runs on. Returns the resulting settings with changed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "enum": MCPDataStore.aiTaskSettingsTargets, "description": "default_model, docs, background_text, background_multimodal, task_model, meetings, data_privacy, host, or backups."],
                        "task_id": ["type": "string", "description": "For target task_model: the background task, an id from get_ai_task_settings' tasks (for example meeting_action_items). With provider and model it gives that task a model of its own; with neither it goes back to following background_text or background_multimodal."],
                        "provider": ["type": "string", "description": "Provider id from the catalogue (anthropic, openai, gemini, xai, meta, openrouter)."],
                        "model": ["type": "string", "description": "Model id from the catalogue for that provider, or a free model id from free_models (provider openrouter). For target host: the model to choose a host for, defaulting to what host_for runs on now."],
                        "hide_training_models": ["type": "boolean", "description": "For target data_privacy: true hides the models that train on what is sent to them (trains_on_inputs) from every picker, as the Data & Privacy switch does; false shows them, labelled."],
                        "meetings_may_use_free": ["type": "boolean", "description": "For target meetings: true lets meeting tasks run on a free Background model; false keeps them on a paid one while it is free, since a meeting's transcript holds private conversations."],
                        "host_for": ["type": "string", "enum": ["chat", "background_text", "background_multimodal"], "description": "For target host: whose host to choose — chat, background_text or background_multimodal."],
                        "host": ["type": "string", "description": "For target host: automatic (the fastest host that caches prompts), cheapest, or an endpoint tag from OpenRouter's GET /api/v1/models/{slug}/endpoints, such as deepinfra/fp4."],
                        "host_fallback": ["type": "boolean", "description": "For target host with a pinned host: true (the default) lets another host take over when it refuses; false fails the work instead."],
                        "host_region": ["type": "string", "enum": ["us", "any"], "description": "For target host: us keeps the host choice to the model's hosts OpenRouter lists as running in the US, so no host elsewhere (such as in China) runs the work; any lifts it. Omitted, the stored region stays; with host omitted, only the region changes."],
                        "backups_for": ["type": "string", "enum": ["chat", "background_text", "background_multimodal"], "description": "For target backups: whose backups to set — chat (the Default Model's, used only by a scheduled task's runs), background_text or background_multimodal."],
                        "backups": [
                            "type": "array",
                            "description": "For target backups: the whole ordered list of backup models, at most \(AIBackupModels.limit), each a provider and model the same setting would accept as its selection (a free model from free_models too). [] removes them.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "provider": ["type": "string", "description": "Provider id from the catalogue."],
                                    "model": ["type": "string", "description": "Model id from the catalogue, or a free model id from free_models (provider openrouter)."],
                                ],
                                "required": ["provider", "model"],
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                    "required": ["target"],
                ]
            ),
            MCPToolDef(
                name: "merge_meeting_groups",
                description: "Merge one meeting series into another — what dropping a meeting folder onto another does in Sources. Every session and artifact of source_group_id moves to target_group_id, the source folder disappears, and its id is kept as an alias so links to it keep resolving. Both ids come from list_meeting_groups; a folder's id is not its title.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_group_id": ["type": "string", "description": "The meeting group to fold in. It ceases to exist as a folder."],
                        "target_group_id": ["type": "string", "description": "The meeting group that receives the sessions."],
                    ],
                    "required": ["source_group_id", "target_group_id"],
                ]
            ),
            MCPToolDef(
                name: "merge_meeting_sessions",
                description: "Fold the sessions of one meeting series that are really one sitting into one session — the series' Merge Same-Day Sessions in the sidebar. A free Zoom account ends a call after forty minutes and the host starts a new meeting, so one standup arrives as two recordings and two sessions; ForeverLM already folds such a pair as the second transcript lands (same local day, started within four hours). This is the hand-driven form for sessions split before that rule existed or filed by hand. Pass group_id (from list_meeting_groups) to fold every day of the series that holds more than one finished session, with date (YYYY-MM-DD, the learner's local day) to do one day only; or pass source_ids (two or more session ids of one series, from get_meeting_group) to fold exactly those. The session that started first survives with its id, URL, title and date; the others' transcript, notes, chat and recording sections are appended in start order under a “Reconnected at HH:MM” line, their files, Notebook membership, chats and highlights move to it, and their rows are archived so the same recording is never filed again. The survivor's action items are read afresh. Idempotent: a series already at one session a day answers nothing_to_merge.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "Meeting group id from list_meeting_groups (a title is accepted too). Required unless source_ids is given."],
                        "date": ["type": "string", "description": "With group_id: fold only the sessions of this local day, YYYY-MM-DD. Omit to fold every day that holds more than one."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Two or more session source ids of one series to fold into the one that started first. Overrides group_id and date."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "delete_meeting_group",
                description: "Delete a meeting series for good — the app's Delete Series. Every session in the folder, archived ones included, and their artifacts are deleted with it; the Drive folder and the recordings behind it are not touched. This cannot be undone: call get_meeting_group first and confirm the title and session count with the learner before deleting.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "Meeting group id from list_meeting_groups."],
                    ],
                    "required": ["group_id"],
                ]
            ),
        ]
    }
}
