// MCPToolRegistry: the source tools tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var sourceToolsToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "move_source_type",
                description: "Change a source's type (e.g. reclassify an article as a paper).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID"],
                        "new_type": ["type": "string", "enum": ["article", "paper", "podcast", "book", "course", "video", "meeting", "manual", "unclassified"], "description": "Target source type"],
                    ],
                    "required": ["source_id", "new_type"],
                ]
            ),
            MCPToolDef(
                name: "remove_all_from_podcast",
                description: "Remove every episode of a podcast show (matched by show name) — dismiss + archive each, like Studio's 'Remove All from <show>'.",
                inputSchema: [
                    "type": "object",
                    "properties": ["show_name": ["type": "string", "description": "Podcast show name as shown in Studio"]],
                    "required": ["show_name"],
                ]
            ),
            MCPToolDef(
                name: "delete_review_session",
                description: "Delete a review session (or saved external session link) by ID.",
                inputSchema: [
                    "type": "object",
                    "properties": ["session_id": ["type": "string", "description": "Review session ID"]],
                    "required": ["session_id"],
                ]
            ),
            MCPToolDef(
                name: "update_review_session_sources",
                description: "Replace the set of sources linked to a review session. On a day's memory review (id memory-YYYY-MM-DD) a source left out of the set is removed from the day, as the × on its chip does: the tutor stops asking about it when the review is next opened, and a reopen on any device leaves it out.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Review session ID"],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs to link (replaces the current set)."],
                    ],
                    "required": ["session_id", "source_ids"],
                ]
            ),
            MCPToolDef(
                name: "update_review_session",
                description: "Rename a review session or chat, file it under a Notebook, pin it, or hide it from the sidebar — what the chat's sidebar row offers. Omit a field to keep it; pass notebook_id \"\" to move the chat out of its Notebook into the ungrouped Chats list. Linked sources are changed with update_review_session_sources.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Review session ID from get_review_sessions."],
                        "title": ["type": "string", "description": "New title. Must not be empty."],
                        "notebook_id": ["type": "string", "description": "The Notebook (from list_notebooks) or the Goal (from list_goals) to file the chat under — a chat clearly about a Goal's sources belongs on that Goal, where its row and editor list it and its reviews read it as history; \"\" removes it from its Notebook or Goal."],
                        "is_hidden": ["type": "boolean", "description": "Optional: true hides the chat from the sidebar on every Mac signed into this account (the Hidden fold under Chats lists it again), false shows it. The chat, its transcript, its Notebook and its team copies are untouched, and search and get_review_sessions still find it; only the hide itself syncs."],
                        "is_pinned": ["type": "boolean", "description": "Optional: true pins the chat, as its row's Pin Chat does: Home's sidebar lists it under Pinned, newest pin first, on every device signed into this account; false unpins it. Only the pin syncs, never the chat's record; a day's memory review is never pinned. get_review_sessions marks pinned chats [pinned]."],
                    ],
                    "required": ["session_id"],
                ]
            ),
            MCPToolDef(
                name: "extract_paper_metadata",
                description: "Run AI metadata extraction (author, journal, year, DOI) for an existing paper source.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Paper source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "extract_article_metadata",
                description: "Run AI title/author extraction for an article source.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Article source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "find_duplicate_papers",
                description: "Detect duplicate papers across the library with AI. Reports duplicate groups; if archive_duplicates is true, archives the lower-quality copy in each group and keeps the best.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "archive_duplicates": ["type": "boolean", "description": "If true, archive the lower-quality duplicates (default false = report only)."],
                    ],
                    "required": [],
                ]
            ),
            MCPToolDef(
                name: "find_podcast_match",
                description: "Search Apple Podcasts for an episode matching a source (by YouTube URL or title) and stage the match for confirmation.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "resolve_podcast_match",
                description: "Confirm or reject a podcast match staged by find_podcast_match. Confirm converts the source to a podcast episode; reject reverts it to queued.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID with a pending podcast match"],
                        "confirm": ["type": "boolean", "description": "true to confirm, false to reject"],
                    ],
                    "required": ["source_id", "confirm"],
                ]
            ),
            MCPToolDef(
                name: "find_podcast_on_youtube",
                description: "Find the YouTube upload of a podcast episode whose transcript Apple Podcasts does not give: the Reader's Find on YouTube. ForeverLM reads the episode's own web page for the video it links, the show's YouTube channel (known from earlier episodes whose transcript came from YouTube) for uploads near the episode's release, and YouTube search, then ranks what it found with the learner's model, best match first; each candidate says where it was found (found_by). Nothing is attached. An upload is often titled differently from the episode, so show the learner the best match and, once they confirm it is this episode, call import_podcast_youtube_transcript with its url. always_for_show ticks the Reader's \"Always find <show> on YouTube\" for the episode's show, so its later episodes with no Apple transcript go straight to YouTube; false unticks it. Needs YouTube connected in Plugins › YouTube.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Podcast episode source ID."],
                        "always_for_show": ["type": "boolean", "description": "Optional. true ticks \"Always find <show> on YouTube\" for the episode's show, false unticks it; omit to leave it as it is."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "import_podcast_youtube_transcript",
                description: "Attach a YouTube video's captions to a podcast episode as its transcript: the Reader's Use Transcript, for a video the learner confirmed is this episode (from find_podcast_on_youtube, or a link they found themselves). The episode keeps its Apple Podcasts identity and records the video as where its transcript came from. It is readable as soon as the call answers; ForeverLM then formats the captions into paragraphs and removes ad reads with the learner's model in the background (the returned work_id; cancel_ai_work stops it and the raw captions stay). An episode that already has its transcript is refused unless replace is true.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Podcast episode source ID."],
                        "video": ["type": "string", "description": "The YouTube video: its address (youtube.com/watch?v=…, youtu.be/…) or its 11-character id."],
                        "replace": ["type": "boolean", "description": "Replace a transcript the episode already has. Defaults to false."],
                    ],
                    "required": ["source_id", "video"],
                ]
            ),
            MCPToolDef(
                name: "refetch_source_content",
                description: "Re-fetch a source's content from its URL and store it, clearing an error state. A web article is refreshed exactly as the app's Refresh from Website does it: read through ForeverLM's signed-in browser, cleaned, and stored with its re-archived page only when the site showed no bot check and returned at least as much text as the saved article, so a paywall preview never replaces it. A podcast episode's transcript is fetched again from Apple Podcasts the way the app fetches one, never its page's text, in the background: the answer names the work, cancel_ai_work stops it, and the stored transcript stays until the new one is saved.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "import_local_pdf_as_paper",
                description: "Import a local PDF file from disk as a NEW paper source: it is copied into the synced Papers folder, its text extracted, and saved at once with its PDF; the Paper Metadata model and Source Content Cleanup then read it in the background, so the answer comes in seconds with the paper's id and a work_id (list_running_ai_work shows it while it runs; cancel_ai_work stops it and the paper keeps its PDF). Several imports can be sent together: each answers at once and their reading waits its turn. When the work is done the paper carries its title, authors, venue and year and get_source_content returns its text; a failure is saved on the paper, and extract_paper_metadata retries it. A paper the library already holds under the DOI printed in the PDF answers with its id instead, and one it holds without a PDF takes this one. To attach a PDF to an existing paper use attach_pdf_to_paper instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": ["type": "string", "description": "Absolute local path to a PDF file"],
                        "title": ["type": "string", "description": "Optional title override"],
                    ],
                    "required": ["file_path"],
                ]
            ),
            MCPToolDef(
                name: "import_local_file",
                description: "Import a file on this Mac into the library the way the app's own import of it does, whatever it is: a PDF as a paper (as import_local_pdf_as_paper does) or as a book, an EPUB or DRM-free Kindle file (azw, azw3, mobi, prc) as a book, a plain text or Markdown file (txt, md, markdown) as a text source. A paper is saved at once with its PDF and read by the models in the background, as import_local_pdf_as_paper does. A book goes through Add Book's importer: its title and author are read, it is split into chapters by the book chapter splitting model, and each chapter is filed under the book, with its cover. A paper or a book runs in the background, a few minutes for a long book, so the answer comes at once with a work_id (list_running_ai_work shows it, cancel_ai_work stops it); afterwards a paper carries its metadata, and for a book list_sources with source_type book, or search_sources_keyword for its title, lists the chapters. kind auto (the default) takes a PDF of 100 pages or more for a book and a shorter one for a paper; pass kind paper or book to choose. The file must be in the ForeverLM library or the Desktop, Documents or Downloads folder. A scanned PDF needs a text layer for its chapters to be found. title applies to a paper only: a book takes its title from the file, and a text source from its text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": ["type": "string", "description": "Absolute local path to the file (a PDF, EPUB, Kindle, text or Markdown file)"],
                        "kind": [
                            "type": "string",
                            "enum": ["auto", "paper", "book", "text"],
                            "description": "What to make of the file. auto (the default) chooses from the file: a PDF of 100 pages or more is a book, a shorter one a paper; an EPUB or Kindle file is a book; a text or Markdown file is text.",
                        ],
                        "title": ["type": "string", "description": "Optional title override for a paper"],
                    ],
                    "required": ["file_path"],
                ]
            ),
            MCPToolDef(
                name: "fetch_video_transcript",
                description: "Fetch and store the transcript for a YouTube video source, a one-off Zoom cloud-recording link (zoom.us/rec/play or /rec/share), or a Teachable lecture. YouTube: also extracts representative slide screenshots from storyboards when available. Zoom: prefers the recording's own transcript/captions and falls back to managed OpenAI transcription; passcode-protected recordings fail with a passcode request — ask the user for the passcode and retry with the passcode argument. An accepted Zoom passcode is saved securely in Keychain and reused for that source. Teachable: the lecture's audio is downloaded and transcribed in the background, a few minutes per lecture; the call returns at once and a later call (or get_source_content) returns the transcript — the learner must be signed in to the school inside ForeverLM. Errors are surfaced directly when a transcript is unavailable.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Video source ID"],
                        "passcode": ["type": "string", "description": "Passcode for a protected Zoom recording (only needed when a previous call reported one is required)"],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "list_video_cited_papers",
                description: "List the source candidates recorded for a source: papers found on a video's slides, papers explicitly mentioned in a meeting's transcript and notes, papers a paper's reference list cites, or — for a web article — the sources its links point at (other articles, papers, videos, podcasts; see scan_article_for_linked_sources). Each candidate carries a kind (paper, article, video, podcast, xPost), a url, and a status: 'pending' can be imported, 'unresolved' was observed but no matching record was found (dismiss only), 'imported' is already in the library (see imported_source_id), 'dismissed' was waved off and can be restored. A linked source also carries context: one line on what the article says about it. Use scan_video_for_cited_papers for videos, scan_meeting_for_mentioned_papers for meetings, scan_article_for_linked_sources for articles.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Video, meeting, paper or article source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "import_video_cited_paper",
                description: "Import one candidate from list_video_cited_papers into the library, through the pipeline its kind takes: a paper through the paper path (deduplication, metadata enrichment, PDF download), a video with its transcript, an article with its archived page. The candidate is then marked imported and linked to the source it produced. Requires a candidate with a url; unresolved candidates fail with an explanation and already-imported candidates are reported rather than imported again. Import only the candidates the learner asked for.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "cited_paper_id": ["type": "string", "description": "Candidate ID from list_video_cited_papers or scan_article_for_linked_sources"],
                    ],
                    "required": ["cited_paper_id"],
                ]
            ),
            MCPToolDef(
                name: "update_video_cited_paper_status",
                description: "Dismiss a candidate from list_video_cited_papers, or restore one that was dismissed. Pass status 'dismissed' to wave a candidate off, or 'pending' to put it back in play (a candidate with neither a DOI nor a url is restored as 'unresolved'). An imported candidate cannot be changed here — remove its library source instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "cited_paper_id": ["type": "string", "description": "Candidate ID from list_video_cited_papers"],
                        "status": ["type": "string", "enum": ["dismissed", "pending"], "description": "'dismissed' to wave the candidate off, 'pending' to restore a dismissed one"],
                    ],
                    "required": ["cited_paper_id", "status"],
                ]
            ),
            MCPToolDef(
                name: "extract_video_slides",
                description: "Capture a library video's slide frames so they can be shown and read, without reading them for cited papers. This is the opt-in first step: slides are no longer captured at ingest (it downloads storyboards and streams the video for frames, so it takes noticeably longer on a long talk), so a YouTube video with a transcript has none until this runs. Idempotent — a video that already has frames just reports how many. Makes no model calls. Follow with scan_video_for_cited_papers to read the captured slides for the papers they cite.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Video source ID"],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "scan_video_for_cited_papers",
                description: "Read a library video's distinct captured slides for the papers they cite, and record what is found. Works on any YouTube video with a transcript: if it has no captured slide frames yet, they are captured first (this downloads storyboards and streams the video for frames, so it takes noticeably longer on the first pass) — or capture them beforehand with extract_video_slides. Neither capture nor scan runs automatically. Independent slides are read concurrently. The default scan is spend-bounded to 40 slides and reports any skipped slides; pass all_slides true to read the complete captured deck and fully resolve its citations. By default a video that already has candidates is NOT rescanned, because that would put back papers already imported or dismissed; pass force to re-extract the slides with current detection and merge, keeping every existing decision and adding only genuinely new papers.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Video source ID"],
                        "force": ["type": "boolean", "description": "Rescan a video that already has candidates and merge the results, preserving existing statuses. Defaults to false."],
                        "all_slides": ["type": "boolean", "description": "Read every distinct captured slide and fully resolve its citations. Defaults to false, which reads at most 40 slides and reports how many were skipped."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "scan_article_for_linked_sources",
                description: "Read a web article's saved page for the sources its links point at — other articles and essays, papers, videos, podcast episodes, the author's earlier posts — and record each as a candidate the learner can add. This is how \"find all the linked sources\" is answered: call it with the article's source_id, show the learner the returned candidates (title, kind, site, context — what the article says about each), and import only the ones they pick with import_video_cited_paper. The links are read off the page deterministically; a model judges which of them the article uses as sources and describes each, and never invents or rewrites an address. Page plumbing (subscribe, share, profiles, tag pages, image files) is left out. An article with no saved page is fetched and archived first. By default an article that already has candidates is NOT rescanned — that would put back sources already imported or dismissed — and the existing candidates are returned; pass force to read the links again and merge, keeping every existing decision and adding only genuinely new sources.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Article source ID"],
                        "force": ["type": "boolean", "description": "Rescan an article that already has candidates and merge the results, preserving existing statuses. Defaults to false."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "make_article_reading_view",
                description: "Change how the learner reads one web article, in their own words, without changing the article: \"remove the inline citations\", \"hide the subscribe bar\", \"leave out the footnote numbers\". A model reads the article and names the exact pieces of its text to hide; the Reader then hides them on the page and the learner can switch back to the original any time. The article's saved page, its text, highlights, chat and search are untouched — only the Reader changes, and only on this Mac. Replaces the article's earlier reading view. Pass the learner's wish as the instruction, in plain words. If the model finds nothing matching the instruction, nothing is saved and the existing reading view stays. Answers with how many pieces are hidden and a few examples; tell the learner to open the article in the Reader, and show them what was hidden if they ask.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Article source ID"],
                        "instruction": ["type": "string", "description": "How the learner wants to read it, in their own words, for example 'Remove all inline citations like (Lewontin 1970)'"],
                    ],
                    "required": ["source_id", "instruction"],
                ]
            ),
            MCPToolDef(
                name: "get_article_reading_view",
                description: "Read an article's reading view: whether the learner has one, the instruction it was made from, whether the Reader currently shows it or the original, how many pieces of text it hides, and the first pieces as examples.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Article source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "set_article_reading_view_shown",
                description: "Switch an open or future Reader between the learner's reading view of an article and the original page. The reading view is kept either way, so switching back costs nothing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Article source ID"],
                        "shown": ["type": "boolean", "description": "true to read the reading view, false to read the original"],
                    ],
                    "required": ["source_id", "shown"],
                ]
            ),
            MCPToolDef(
                name: "clear_article_reading_view",
                description: "Delete an article's reading view, so the Reader shows the original page and the list of hidden pieces is gone. Make a new one with make_article_reading_view.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Article source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "scan_meeting_for_mentioned_papers",
                description: "Read a meeting source's complete stored transcript and notes for academic papers participants explicitly mention, resolve each candidate against scholarly records, and save the results for import or dismissal. A recording-only meeting is transcribed on-device first. By default a meeting with existing candidates is not rescanned; pass force to scan again and merge genuinely new candidates while preserving every prior decision. Fails when the meeting has no readable material or recording.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Meeting source ID"],
                        "force": ["type": "boolean", "description": "Rescan and merge while preserving existing statuses. Defaults to false."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "fetch_source_from_archive",
                description: "Fetch article text from archive.ph for a paywalled or errored web source and store it as source content.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "Article source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "clear_source_derived_data",
                description: "Clear cached source text and embeddings without archiving or deleting the source.",
                inputSchema: [
                    "type": "object",
                    "properties": ["source_id": ["type": "string", "description": "The source ID"]],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "set_source_read",
                description: "Mark a source read or unread — the reader's Mark as Read. Web articles, papers and videos track a read state; other source types are refused. Marking read stamps now; marking unread clears the stamp. For a video, read means watched, as in the sidebar's Mark as Watched and Mark as Not Watched: false clears its watch progress and any read stamp on every device, true finishes a video that has played in the Reader (its length is needed) and is refused for one that never has. The Schedule's completion state is separate: set_source_completion.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Source ID from list_sources."],
                        "read": ["type": "boolean", "description": "true to mark read (a video: watched), false to mark unread (a video: not watched). Defaults to true."],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "update_source",
                description: "Update metadata of an existing source (title, author, type, paper venue/year/DOI, parent_group, content, paywall status).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "The source ID to update"],
                        "title": ["type": "string", "description": "New title (optional)"],
                        "author": ["type": "string", "description": "New author (optional)"],
                        "source_type": ["type": "string", "enum": ["article", "paper", "podcast", "book", "course", "meeting", "video", "xPost", "manual", "unclassified"], "description": "New source type (optional)"],
                        "journal": ["type": "string", "description": "Paper venue/journal (optional)"],
                        "published_year": ["type": "string", "description": "Paper publication year (optional)"],
                        "doi": ["type": "string", "description": "Paper DOI (optional)"],
                        "is_paywalled": ["type": "boolean", "description": "Paywall status for article/paper/unclassified sources (optional)"],
                        "parent_group": ["type": "string", "description": "New course/book display title or stable group ID (optional)"],
                        "content": ["type": "string", "description": "New content text (optional)"],
                    ],
                    "required": ["source_id"],
                ]
            ),
        ]
    }
}
