// Canonical directory-facing contract for the official ForeverLM ChatGPT and
// Claude extensions. The gateway replaces every upstream tools/list descriptor
// with these schemas and impact annotations, so a hosted account, a live Mac,
// and the isolated review fixture cannot advertise different contracts.
//
// The tools themselves are NOT written here. `mcp-tools.generated.json` is
// emitted from the app's own `MCPToolRegistry` by `MCPToolContractTests`, which
// fails when the two disagree — so a tool added to the Mac is published here
// automatically and the gateway cannot fall behind it. Each entry carries its
// `readOnlyHint` from the registry too (`MCPToolRegistry.isReadOnlyTool`): the
// Mac's list is the only one, because the gateway lets only reads fall back to
// the hosted mirror once the Mac may have run a call, and two lists disagreed
// (design review 2026-10-09). This file owns the rest: the destructive and
// open-world annotations the directories require, and the tools the Worker
// implements itself.
//
// It used to hold a second, hand-written copy of all of it, and by 2026-09-18
// that copy had silently fallen 98 tools behind the app.
import generated from "./mcp-tools.generated.json";

export type JSONSchema = Record<string, unknown>;

export type ToolDefinition = {
  name: string;
  title: string;
  description: string;
  inputSchema: JSONSchema;
  outputSchema?: JSONSchema;
  _meta?: Record<string, unknown>;
  /// MCP tool icons. Codex draws a tool's global entrypoint (the "Open
  /// ForeverLM" row in its sidebar menu) with the first of these.
  icons?: Array<{ src: string; mimeType?: string; sizes?: string[]; theme?: "light" | "dark" }>;
  annotations: {
    readOnlyHint: boolean;
    destructiveHint: boolean;
    openWorldHint: boolean;
  };
};

/// Tools that reach beyond the library — they write a source built from
/// material fetched elsewhere, so a client should treat their effects as
/// touching the wider world rather than only local state.
const openWorld = new Set([
  // Draws through the learner's image model on OpenRouter, billed to their own key.
  "generate_image",
  "generate_source_audio",
  "add_source",
  "recheck_paywalled_papers",
  "transcribe_meeting_recording",
  // Reaches outside the library: the live web, a provider, or a connected
  // account. create_x_post publishes to X in the learner's own name.
  "add_sources",
  "attach_pdf_to_paper",
  "attach_supplementary_pdf",
  "create_x_post",
  "download_papers_needing_attention",
  "extract_article_metadata",
  "extract_paper_metadata",
  "extract_video_slides",
  "fetch_source_from_archive",
  "fetch_video_transcript",
  // Searches PubMed's index of the published literature and the preprints it carries.
  "search_literature",
  "find_duplicate_papers",
  "find_lecture_papers",
  "find_podcast_match",
  // Read the episode's own page and YouTube for its upload, and rank or format
  // what they find with the learner's model.
  "find_podcast_on_youtube",
  "import_podcast_youtube_transcript",
  "follow_youtube_foreverlm_playlist",
  "follow_youtube_liked_videos",
  "generate_course",
  // Writes a course's quizzes with the learner's model, one call per quiz.
  "generate_course_quizzes",
  // Streams lecture videos for their slides and picks them with the learner's model.
  "add_course_quiz_pictures",
  // Plans a textbook's readings into a course with the learner's model.
  "add_textbook_to_course",
  // Fetches the playlist from YouTube and every lecture's transcript.
  "import_youtube_playlist",
  // Reads a Teachable school as the learner and transcribes every lecture's audio.
  "import_teachable_course",
  // Reads the learner's notebook from Google as the learner.
  "import_gemini_notebook",
  "generate_explainer",
  // Reads a Notebook's sources and writes its audio overview with the learner's
  // model, then may narrate it with their voice.
  "generate_audio_overview",
  // Reads a Notebook's sources and writes its report with the learner's model.
  "generate_report",
  // Reads sources whole and drafts their cards with the learner's model.
  "draft_cards",
  // Reads sources whole and writes a mnemonic reading's questions with the
  // learner's model.
  "generate_mnemonic_reading",
  // The sensemaking shapes read the library and write with the learner's
  // model: an Ask's proposals, an Atlas and a concept in depth, a source's
  // reading levels, cards from the Canvas (docs/sensemaking-design.md).
  "ask_canvas",
  "make_atlas",
  "get_atlas",
  "get_source_levels",
  "make_cards_from_canvas",
  // Films scenes with the learner's video model after the Mac's price dialog.
  "generate_explainer_video",
  "import_connector_paper",
  "import_paper_from_url",
  "import_video_cited_paper",
  "ingest_lecture_papers",
  "refetch_source_content",
  "refresh_youtube_sources",
  "scan_article_for_linked_sources",
  "scan_meeting_for_mentioned_papers",
  "scan_video_for_cited_papers",
  // Asks Crossref and OpenAlex about each entry of a paper's reference list.
  "resolve_paper_references",
  // Searches the live web with the learner's chat model and opens each page
  // it lists to check that it is real.
  "discover_sources",
  // OpenAI's tool scan (2026-11-08): these publish, share or rewrite pages and
  // invitations that people outside the learner's library can open, or follow
  // a channel on YouTube.
  "adopt_page",
  "edit_doc",
  "follow_youtube_channel",
  "get_team_invitation_link",
  "publish_doc",
  "restore_doc_version",
  "share_notebook",
  "write_doc",
]);

const destructive = new Set([
  // The list of pieces an article's reading view hides, gone from the Mac.
  "clear_article_reading_view",
  // A canvas in Trash gone forever, with all that was placed on it, on every
  // device.
  "delete_canvas",
  // A list of goals or ideas in Trash gone forever from the Space, on every
  // device; the goals and ideas it held stay.
  "delete_space_list",
  "delete_atlas",
  // Moves the learner's kept picture, or every version of it, to the Trash.
  "delete_image",
  'delete_idea',
  // A Direction gone for good; set aside is the answer that keeps it.
  "delete_direction",
  // A forgotten working note is gone, and its line in the Doc with it.
  "forget_working_note",
  // The learner marked the passage by hand while reading; deleting it throws
  // away their own annotation, not derived state.
  "delete_source_highlight",
  // A plan the learner made leaves the Schedule, and a placement with no
  // activity history is deleted rather than kept.
  "unschedule_sources",
  "clear_schedule_day",
  // A team Notebook's task leaves every member's board.
  "delete_notebook_task",
  // An event leaves the learner's calendar, on every device it syncs to.
  "delete_calendar_event",
  // A span of the day's log is forgotten; the log is the learner's own record
  // of what they did, and nothing derives it again.
  "delete_day_activity",
  // A source's recorded activity — its automatic Schedule entry, activity
  // days and read stamp — goes for good, on every device.
  "forget_source_activity",
  // Removes only the course relationship; the source remains in the library.
  "remove_course_lecture_item",
  // Classified with the registry contract (2026-09-18): each one destroys
  // something the learner made, not state the app can derive again.
  "delete_course",
  // Replaces a course quiz, or removes one.
  "save_course_quiz",
  "delete_course_quiz",
  // Replaces the readings a book already has in the course.
  "save_course_textbook_readings",
  "add_textbook_to_course",
  "delete_meeting_group",
  "delete_notebook",
  "delete_review_session",
  "delete_scheduled_task",
  "delete_source",
  // Dismisses the URL so discovery cannot re-add it, then archives — or deletes outright when the paper was never downloaded.
  "remove_source",
  "remove_all_from_podcast",
  "remove_connector_sources",
  // Throws away stored text and embeddings; re-deriving them costs another fetch and another provider call.
  "clear_source_derived_data",
  // The source folder disappears into the target.
  "merge_meeting_groups",
  // The absorbed sessions' rows are archived and their text folded into the
  // survivor; splitting them apart again is by hand.
  "merge_meeting_sessions",
  // Every notebook but the survivor is folded in and deleted.
  "merge_notebooks",
  // Forgets a link the learner made by highlighting a passage.
  "unlink_doc_chat",
  // Deletes a comment, or a whole thread with whole_thread.
  "delete_doc_comment",
  // Rewrites each source's understanding wholesale; the previous text is not kept.
  "record_understanding",
  // Replaces the synthesis notes. append_notebook_notes is the additive one.
  "update_notebook_notes",
  // Replaces the linked set rather than adding to it.
  "update_review_session_sources",
  // Replaces the stored text of an existing source.
  "update_source_content",
  // Replaces a workspace file's contents; the revision guard catches a stale write, not a deliberate overwrite.
  "write_notebook_markdown_file",
  // A skipped draft is never offered again, and a card from before cards
  // that is skipped is retired, never asked again.
  "triage_cards",
  // Starting a card over retires it and restarts its schedule, and a retired
  // card is never asked again.
  "update_card",
  // OpenAI's tool scan (2026-11-08): each of these deletes, replaces or
  // overwrites something the learner made or set, or ends work, a team
  // membership or a connection, in a way calling it again does not undo.
  // Writing levels for changed text replaces the stale ones; recording a quiz
  // answer again overwrites its grade.
  // Adopting a page discards its live link and replaces ForeverLM's copy with
  // an owned published page. Declining a share request closes it for every
  // member. OpenAI's 1.0.6 review caught both as hard-to-reverse changes.
  "adopt_page",
  "decline_share_request",
  "get_source_levels",
  "record_course_quiz_result",
  "cancel_source_audio_generation",
  "decide_background_ai_job",
  "update_space_list",
  "run_settings_action",
  "save_canvas_version",
  "set_practice",
  "update_course",
  "add_course_quiz_pictures",
  "cancel_ai_work",
  "delete_animation",
  "delete_doc",
  "delete_team",
  "delete_walkthrough",
  "disconnect_plugin",
  "generate_course_quizzes",
  "generate_walkthrough",
  "import_review_chat",
  "leave_team",
  "link_page",
  "make_article_reading_view",
  "make_atlas",
  "publish_doc",
  "save_animation",
  "save_paper_references",
  "save_site",
  "save_walkthrough",
  "set_automatic_audio_settings",
  "set_calendar_settings",
  "set_chat_model_offered",
  "set_course_quiz_picture",
  "set_meeting_schedule",
  "set_own_router_key",
  "share_with_team",
  "unlink_idea",
  "unpublish_doc",
  "update_calendar_event",
  "update_direction",
  "update_doc",
  "update_idea",
  "update_notebook_collection",
  "update_notebook_task",
  "update_source_highlight",
  "update_space",
  "update_working_note",
  "write_doc",
]);

function title(name: string): string {
  return name.split("_").map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(" ")
    .replaceAll("Mcp", "MCP").replaceAll("Ai", "AI").replaceAll("Pdf", "PDF").replaceAll("Url", "URL");
}

/// Registry reads with an effect the directories count (OpenAI's tool scan,
/// 2026-11-08): screenshot_canvas saves its PNG under Exports/,
/// inspect_paper_figure renders and keeps the figure's crop, and
/// find_card_sources spends on an embedding of the card's words. Not read-only
/// here also keeps them off the hosted-mirror fallback.
const leavesAFile = new Set(["screenshot_canvas", "inspect_paper_figure", "find_card_sources"]);

/// Mac tools only the ForeverLM view inside an assistant calls (MCP Apps
/// `visibility: ["app"]`): the host hides them from its model. browse_library
/// answers the view's Library page with thumbnails as data URLs, which would
/// only cost a model tokens.
export const APP_ONLY_TOOL_NAMES: ReadonlySet<string> = new Set(["browse_library"]);

function tool(name: string, description: string, inputSchema: JSONSchema, registryReadOnly: boolean): ToolDefinition {
  const isReadOnly = registryReadOnly && !leavesAFile.has(name);
  return {
    name,
    title: title(name),
    description,
    inputSchema,
    annotations: {
      readOnlyHint: isReadOnly,
      destructiveHint: !isReadOnly && destructive.has(name),
      openWorldHint: openWorld.has(name),
    },
    ...(APP_ONLY_TOOL_NAMES.has(name) ? { _meta: { ui: { visibility: ["app"] } } } : {}),
  };
}

/// Every tool the Mac's `MCPToolRegistry` declares, generated from it by
/// `MCPToolContractTests` and re-checked by that test on every run. The app is
/// the only place a tool is defined; the gateway compiles what the app has,
/// which is what stops this contract falling behind it the way it did before.
const GENERATED_TOOLS = generated as Array<{ name: string; description: string; inputSchema: JSONSchema; readOnlyHint: boolean }>;

/// Tools the Worker implements itself, so they have no registry entry: the
/// hosted iCloud handoff that takes EPUB bytes for a Mac to expand natively,
/// and the app-only launcher that gives Codex and ChatGPT a global ForeverLM
/// home without teaching the model a redundant library action.
const GATEWAY_OWNED_TOOLS: ToolDefinition[] = [
  {
    ...tool(
      "open_foreverlm",
      "Open the learner's ForeverLM home. This launcher is for the plugin UI, not for model use.",
      { type: "object", properties: {}, required: [] },
      true,
    ),
    // Codex labels the entrypoint with the tool's title; the derived one reads
    // "Open Foreverlm".
    title: "ForeverLM",
    // The flat glyph, not the full-colour favicon: beside Codex's line icons the
    // favicon rendered as a black square.
    icons: [
      { src: "https://plugin.foreverlm.com/icon-glyph.png", mimeType: "image/png", sizes: ["128x128"], theme: "light" },
      { src: "https://plugin.foreverlm.com/icon-glyph-dark.png", mimeType: "image/png", sizes: ["128x128"], theme: "dark" },
    ],
    outputSchema: {
      type: "object",
      properties: { status: { type: "string", enum: ["ready"] } },
      required: ["status"],
    },
    _meta: {
      ui: {
        resourceUri: "ui://foreverlm/home-v9.html",
        visibility: ["app"],
      },
      "openai/outputTemplate": "ui://foreverlm/home-v9.html",
      "openai/ui": {
        entrypoints: [{ type: "global" }],
      },
      "openai/toolInvocation/invoking": "Opening ForeverLM…",
      "openai/toolInvocation/invoked": "ForeverLM is ready.",
    },
  },
  tool("import_epub", "Import an EPUB book into the learner's ForeverLM library without flattening it to plain text. Send the original file bytes as base64. ForeverLM stores the untouched EPUB in the learner's iCloud, then a signed-in Mac runs the same native importer as Add Book: chapters, readable text, cover art, and embedded images are preserved. The returned source_id names the queued handoff; after native expansion, call list_sources and match the returned title to obtain the final book_id and chapter source IDs. Accepts files up to 15 MB.", {
    type: "object",
    properties: {
      filename: { type: "string", description: "Original filename ending in .epub. Only the basename is used." },
      content_base64: { type: "string", description: "Complete, unmodified EPUB file bytes encoded as base64." },
      title: { type: "string", description: "Optional display title for the queued import. EPUB metadata remains authoritative during native expansion." },
    },
    required: ["filename", "content_base64"],
  }, false),
];

export const TOOLS: ToolDefinition[] = [
  ...GENERATED_TOOLS.map((entry) => tool(entry.name, entry.description, entry.inputSchema, entry.readOnlyHint === true)),
  ...GATEWAY_OWNED_TOOLS,
].sort((left, right) => left.name.localeCompare(right.name));

export const TOOL_NAMES = new Set(TOOLS.map((definition) => definition.name));

/// The tools that change nothing, by the `readOnlyHint` the contract publishes.
/// The gateway sends only these to the hosted mirror once the relay may have
/// handed the call to the Mac (`mcp.ts`, `writeToolRequested`): a read is safe
/// to run twice, and a write the Mac may already have run is not. A tool on
/// this list must change nothing on any host that serves it.
export const READ_ONLY_TOOL_NAMES: ReadonlySet<string> = new Set(
  TOOLS.filter((definition) => definition.annotations.readOnlyHint).map((definition) => definition.name),
);

/// Tools the gateway answers itself instead of relaying to a host.
///
/// Every other public tool must be implemented by whichever host serves the
/// request, and `tools/list` fails closed when one is missing. Plugin reads
/// live here because only the gateway holds their credentials. import_epub also
/// lives here because its original bytes must enter the hosted iCloud asset
/// handoff before the Mac can run the canonical book importer.
export const GATEWAY_EXECUTED_TOOL_NAMES: ReadonlySet<string> = new Set([
  "open_foreverlm",
  "import_epub",
  "list_slack_channels",
  "read_slack_channel",
  "read_slack_thread",
  "search_slack_messages",
  "get_linear_issue",
  "search_linear_issues",
  "list_linear_issues",
  "list_linear_teams",
  "list_linear_projects",
  "get_linear_project",
  "list_github_repositories",
  "get_github_repository",
  "list_github_files",
  "read_github_file",
  "search_github_code",
  "list_github_issues",
  "get_github_issue",
  "list_github_pull_requests",
  "get_github_pull_request",
  "list_github_commits",
  "search_notion",
  "get_notion_page",
  "list_notion_databases",
  "get_notion_database",
  "query_notion_database",
]);

/// Tools only a reachable Mac can serve.
///
/// Ingestion runs through the app's own importer so a source has exactly one
/// path into the library — the rule that keeps identity, dedup, and derived
/// data consistent. The hosted CloudKit account cannot stand in: writing a
/// source's text needs a CKAsset upload the gateway's CloudKit client does not
/// implement, and an inline copy is discarded by the Mac on decode, which would
/// file a source that silently arrives empty.
///
/// Like the gateway-executed tools, these are exempt from the fail-closed check
/// that every host must advertise every public tool. Unlike them, a call
/// without a reachable Mac is refused with an explanation rather than answered.
/// The Settings-window controls with a chat equivalent that the Mac answers
/// (product rule, 2026-09-22: every setting must be settable from chat).
export const SETTINGS_PARITY_TOOL_NAMES: readonly string[] = [
  "get_app_settings",
  "set_app_setting",
  "run_settings_action",
  "open_settings",
  "open_in_app",
  "rename_team",
  "delete_team",
  "leave_team",
  "open_team_library",
  "get_team_invitation_link",
  "get_chat_models_offered",
  "set_chat_model_offered",
  "get_billing_settings",
  "get_background_ai_jobs",
  "decide_background_ai_job",
  "get_plugin_connections",
  "disconnect_plugin",
  "set_slack_channel_enabled",
  "get_calendar_settings",
  "set_calendar_settings",
  "follow_youtube_channel",
  "unfollow_youtube_channel",
  "list_journal_feeds",
  "follow_journal_feed",
  "unfollow_journal_feed",
];

/// The tools that edit the learner's Canvas on their word
/// (`MCPToolRegistry.canvasEditToolNames`): cards, a card's look, Tidy Up and
/// Align, regions, arrows, Undo, keeping a lens and the display switches.
export const CANVAS_EDIT_TOOL_NAMES: readonly string[] = [
  "place_on_canvas",
  "take_off_canvas",
  "canvas_region",
  "canvas_arrow",
  "undo_canvas",
  "keep_map_lens",
  "set_canvas_display",
  "build_canvas",
  // A canvas's versions kept on this Mac, and one put back as an edit Undo
  // takes back (`MCPToolRegistry.canvasEditToolNames`).
  "save_canvas_version",
  "restore_canvas_version",
  "update_canvas_card",
  "arrange_on_canvas",
];

/// The tools that list the learner's canvases and make, open, rename, file,
/// pin, trash or delete one on their word
/// (`MCPToolRegistry.canvasCatalogToolNames`).
export const CANVAS_CATALOG_TOOL_NAMES: readonly string[] = [
  "list_canvases",
  "create_canvas",
  "open_canvas",
  "update_canvas",
  "delete_canvas",
  "list_canvas_versions",
];

/// The tools that list the versions a canvas has on this Mac and keep or
/// restore one (`MCPToolRegistry.canvasVersionToolNames`); they sit in the two
/// lists above too, and say why the Mac is needed in words of their own.
export const CANVAS_VERSION_TOOL_NAMES: readonly string[] = [
  "list_canvas_versions",
  "save_canvas_version",
  "restore_canvas_version",
];

/// The tools that list the learner's lists of goals and ideas in the Space and
/// make, rename, file, pin, fill, trash or delete one on their word
/// (the Space-list tools in `MCPTools+SpaceLists.swift`).
export const SPACE_LIST_TOOL_NAMES: readonly string[] = [
  "list_space_lists",
  "create_space_list",
  "update_space_list",
  "delete_space_list",
];

export const DESKTOP_ONLY_TOOL_NAMES: ReadonlySet<string> = new Set([
  // A paper's reference list is local derived data (schema 174), read from the
  // PDF the Mac holds and linked through the Mac's own catalog requests; an
  // assistant's saved entries are written there too. The hosted account holds
  // none of it. get_paper_references is the one way to read a paper's reference
  // text, since get_source_content leaves bibliography entries out.
  "get_paper_references",
  "resolve_paper_references",
  "save_paper_references",
  // Images are files under the Mac's content root, each carrying its prompt
  // and image id in its own XMP; generate_image draws through the Mac's
  // signed-in image route. The hosted account holds no image files at all.
  "list_images",
  "get_image",
  "generate_image",
  "save_image",
  "rename_image",
  "delete_image",
  // Every other Settings control (MCPTools+AppSettings.swift and its two
  // siblings): the app's own preferences, Keychain items, plugin grants,
  // teams and the billing account, all changed through the Mac's own setters.
  // Only those the generated contract already carries: the app declares a
  // tool before `MCPToolContractTests` regenerates the file.
  ...SETTINGS_PARITY_TOOL_NAMES.filter((name) => GENERATED_TOOLS.some((entry) => entry.name === name)),
  // Settings › Memory is app preference state — the budget and the daily
  // switch sync, the hour and the receipts are this Mac's.
  "get_memory_review_settings",
  "set_memory_review_settings",
  // A source's cards to check live in its private draft deck, a Markdown body
  // in the Mac's library the hosted account cannot write, and what the learner
  // kept or skipped is the app's own synced preference row; a kept card is a
  // Memory item the Mac's scheduler deals (docs/memory-design.md).
  "save_card_drafts",
  "list_cards",
  // Which sources have cards is read from the Mac's own card anchors.
  "list_source_card_coverage",
  // The nearest passages of other sources to a card, retrieved from the Mac's
  // embeddings of its sources' text.
  "find_card_sources",
  "triage_cards",
  // Today's cards are dealt by the Mac's scheduler from its attempts, an
  // answer is recorded there as the card review records it, and a kept
  // card's wording and state are its own rows.
  "get_due_cards",
  "record_card_result",
  "update_card",
  // The chosen cards are dealt by that scheduler into the app's own card
  // review, which opens in the Mac's window.
  "practice_cards",
  // Study practices are Practice records the Mac keeps on the new iCloud sync,
  // and adopting one applies its setting through the Mac's own setters
  // (docs/cloudkit-schema-design.md §8c).
  // The ForeverLM view's Library page: books folded from their chapters
  // and every picture drawn from the Mac's own files and artwork cache.
  "browse_library",
  "list_practices",
  "decide_practice",
  "set_practice",
  // Drafting reads the sources' whole text the Mac holds, with the Card
  // Drafting model chosen there, and appends to their private draft decks.
  "draft_cards",
  // An Idea is a row in the Mac's own store and its chips resolve against
  // that library; the tab it lives in is the app's (docs/ideas-design.md).
  "list_ideas",
  "create_idea",
  "update_idea",
  "link_idea",
  "unlink_idea",
  "delete_idea",
  // A Direction is a row in the Mac's own store toward a Goal, Notebook or
  // Idea there, and the brief reads that library, its Ideas and its answers;
  // the literature search runs from the Mac beside them
  // (docs/directions-design.md).
  "find_directions",
  "search_literature",
  "propose_directions",
  "list_directions",
  "update_direction",
  "delete_direction",
  // A notebook's Discover runs the Mac's chat model with that library's
  // Notebook as context, checks each page it lists from the Mac, and marks
  // what that library already holds (docs/notebooks-design.md).
  "discover_sources",
  // A reading view is a file on the Mac that the Reader there draws from; the
  // model that names what to hide runs from the Mac with its Article Cleanup
  // model (docs/article-reading-view-design.md).
  "make_article_reading_view",
  "get_article_reading_view",
  "set_article_reading_view_shown",
  "clear_article_reading_view",
  // The learner's working notes are a file beside the Mac's own store, written
  // when its day closes and through these tools (docs/planner-design.md).
  "list_working_notes",
  "save_working_note",
  "update_working_note",
  "forget_working_note",
  "add_source",
  // A source's activity days hang from a placement in the Mac's own store,
  // and forgetting them is the placement's deletion from there, with the read
  // stamp and any assignment the completion closed (docs/schedule-design.md).
  "forget_source_activity",
  // Course identity, lecture relationships, and source reclassification are
  // native storage operations. Keep the lookup and write sequence on one Mac
  // so stable IDs cannot be resolved against a stale hosted projection.
  "list_courses",
  "get_course",
  "get_lecture_papers",
  "create_course",
  "update_course",
  "create_course_lecture",
  "rename_course_lecture",
  "add_source_to_lecture",
  "add_paper_to_lecture",
  "remove_course_lecture_item",
  // A course's quizzes live in the Mac's store with its outline, and the
  // writer reads the lectures' stored transcripts there.
  "generate_course_quizzes",
  "add_course_quiz_pictures",
  "get_course_quiz",
  "save_course_quiz",
  "delete_course_quiz",
  "rename_course_quiz",
  "set_course_quiz_picture",
  "record_course_quiz_result",
  // A textbook's readings are authored or planned from the Mac's chapter files
  // and stored with the outline.
  "save_course_textbook_readings",
  "add_textbook_to_course",
  "move_source_type",
  // The app's own playlist importer, run in the open Studio window: the
  // hosted library has no course importer to fall back on.
  "import_youtube_playlist",
  // The Teachable importer reads the school with the in-app web session's
  // sign-in and transcribes the audio on the Mac.
  "import_teachable_course",
  // The notebook is read with the Google sign-in made inside ForeverLM on the
  // Mac, and filed through the app's own source, chat and Doc routes.
  "import_gemini_notebook",
  // Rechecking can use the reader's authenticated publisher session and then
  // files the recovered PDF through the app's canonical paper importer.
  "recheck_paywalled_papers",
  // Transcription downloads the recording, extracts audio, and chunks it with
  // AVFoundation before any provider call. That media work is on-device by
  // construction, so the hosted CloudKit account cannot stand in for a Mac.
  "transcribe_meeting_recording",
  // A raw Zoom recording is files in the Mac's own Zoom folder, and only the
  // Zoom client on that Mac can convert it; the ignore list is the Mac's
  // defaults. Listed here so a Mac on a build that predates the two tools
  // still answers `tools/list`.
  "list_unconverted_zoom_recordings",
  "resolve_unconverted_zoom_recording",
  // Text-to-speech audio is generated, chunked, and stored by the app with the
  // voice chosen in its Settings, and the batch queue that paces a whole
  // library through the provider is app state. Nothing hosted can stand in.
  "generate_source_audio",
  "get_source_audio_status",
  "cancel_source_audio_generation",
  // What is running and spending money is the Mac's own: its tool calls in
  // flight, its video films, its queues and drains. A stop has to reach the
  // process doing the work, and only the Mac holds it; a resume lets the
  // Mac's own queues run again.
  "list_running_ai_work",
  "cancel_ai_work",
  "resume_ai_work",
  // The keyword sweep reads every source's stored full text and counts literal
  // matches in it. That text is the Mac's local SQLite; the hosted CloudKit
  // account holds source assets it would have to download one by one to answer
  // a single search, so there is no hosted stand-in. Being listed here also
  // exempts the tool from the missing-tools check in `filterToolListPayload`,
  // which otherwise fails `tools/list` closed for every Mac still on a build
  // that predates the tool — an additive tool must not break older clients.
  "search_sources_keyword",
  // Listing a show's episodes or an author's papers reads the Mac's own
  // source metadata, hidden shows and AI-excluded families already dropped;
  // the hosted account has no copy of that boundary to filter with.
  "list_shows",
  "filter_sources",
  // Today's memory review is scheduled by the Mac: the due concepts, their
  // rubrics and retrieval history live in the app's own SQLite, and starting
  // the session marks items served there. The hosted projection holds none of
  // that scheduler state. Being listed here also exempts the tool from the
  // missing-tools check in `filterToolListPayload`, so a Mac on a build that
  // predates it still answers `tools/list`.
  "memory_review",
  // A figure is rendered from the paper's own PDF, and a slide from the frames
  // captured on this Mac; the picture travels back as an MCP image part. The
  // hosted account holds neither the file nor the renderer. Listed here so a
  // Mac on a build that predates the two tools still answers `tools/list`.
  "inspect_paper_figure",
  "show_source_image",
  // Meeting groups and their folder-image preference are native app state.
  // Keep reads and writes on the same host so callers resolve the stable group
  // ID immediately before changing its synced sidebar preference.
  "list_meeting_groups",
  "get_meeting_group",
  "set_meeting_folder_image",
  // A group's title is a row in the Mac's own store, and the sidebar that
  // shows it is what the rename is for.
  "rename_group",
  // Folding two calls of one standup into one session rewrites the survivor's
  // stored text, moves the absorbed sessions' files, and archives their
  // rows — all rows of the Mac's own store, kept consistent in one
  // transaction there. Listed here so a Mac on a build that predates the
  // tool still answers `tools/list`.
  "merge_meeting_sessions",
  // Settings › Sources is the app's own preferences: the per-family knowledge
  // boundary and the tab bar, written through the app so they sync.
  "get_source_settings",
  "set_source_settings",
  // Which of a Notebook's sources its chats read is the learner's own synced
  // preference row, written through the app so the ticks reach their other
  // devices; the hosted projection holds no preferences to write.
  "set_notebook_source_selection",
  // The learner's collections of notebooks are synced preference rows too,
  // one per collection and one per notebook, written through the app.
  "list_notebook_collections",
  "update_notebook_collection",
  // Settings › Text to Speech › Automatic audio is the app's own preferences too:
  // the per-kind switches (articles, papers, books, courses, explainers),
  // their rules and the paid-voice consent, written through the app so they
  // sync, and priced against the backlog only the Mac's library can size.
  "get_automatic_audio_settings",
  "set_automatic_audio_settings",
  // Settings › General › Day is the app's own preferences: the hours the
  // learner's day runs, written through the app so they sync, and whether
  // this Mac asks "Plan your day?", which is this Mac's alone.
  "get_day_settings",
  "set_day_settings",
  // Settings › AI Usage › API keys is an item in the Mac's Keychain, and
  // routing follows it there.
  "get_own_router_key",
  "set_own_router_key",
  // Settings > AI Models and the AI usage ledger are the app's own: the model
  // routes are preferences the app writes so they sync, and the ledger is the
  // Mac's local SQLite.
  "get_ai_usage_report",
  "get_ai_task_settings",
  "set_ai_task_settings",
  // A Doc's body is a CloudKit asset. The gateway's CloudKit client reads
  // assets but does not upload them, so only the Mac can create or replace a
  // Doc; reads stay on the same host so a read_doc revision is always the one
  // write_doc is compared against.
  "list_docs",
  "create_doc",
  "read_doc",
  "write_doc",
  "edit_doc",
  "update_doc",
  "delete_doc",
  "link_google_doc",
  "unlink_google_doc",
  "link_page",
  "unlink_page",
  "adopt_page",
  "publish_doc",
  "unpublish_doc",
  // A page's versions are bodies this Mac kept just before something replaced
  // them, in its own Application Support beside knowledge.db: nothing syncs
  // them, so another Mac and the hosted account hold none to list or restore.
  "list_doc_versions",
  "restore_doc_version",
  // The learner's spaces of pages are synced preference rows, one per space
  // and one per page, written through the app as the collections are.
  "list_spaces",
  "update_space",
  // So are the learner's lists of goals and ideas in the Space: a row per
  // list and one per goal or idea filed in it, written by the Mac app.
  ...SPACE_LIST_TOOL_NAMES,
  // A site or an animation is files kept in the Mac's library (and synced
  // through the learner's iCloud); nothing puts a copy on the web.
  "save_site",
  "read_site_file",
  "save_animation",
  "list_animations",
  "delete_animation",
  // A walkthrough (of a paper, a book chapter or an article) is written from
  // the Mac's source text and figure index and read by its Reader; the record
  // rides the Mac's own Source row.
  "generate_walkthrough",
  "get_walkthrough",
  "list_walkthroughs",
  "save_walkthrough",
  "delete_walkthrough",
  // An explainer video is filmed, joined and kept under the Mac's content
  // root, after the price dialog only the Mac can show.
  "generate_explainer_video",
  // A Notebook's audio overview is written from the Mac's source text, saved
  // in its library and narrated by its text-to-speech queue.
  "generate_audio_overview",
  // A Notebook's report is written from the Mac's source text with the model
  // chosen there and saved as a Doc in its library.
  "generate_report",
  // A mnemonic reading's questions are written from (and grounded in) the
  // Mac's source text with the model chosen there, kept in a body in its
  // library, and an answer keeps its card in the Mac's Memory, as the card
  // review records one (docs/memory-design.md, "Mnemonic reading").
  "generate_mnemonic_reading",
  "save_mnemonic_reading",
  "get_mnemonic_reading",
  "answer_mnemonic_question",
  // The Map is the Studio window's: the learner's layout is a preference row
  // the Mac merges, and a lens or a focus is drawn in the Mac's Map pane, so
  // there is nothing for the hosted account to show it on.
  "get_knowledge_map",
  "apply_map_lens",
  "clear_map_lens",
  "focus_map",
  // A check of the layout and a picture of the Canvas are drawn from the Mac's
  // Map pane, whose page renders the picture.
  "lint_canvas",
  "screenshot_canvas",
  // The learner's canvases are layout rows the Mac writes, each drawn in its
  // Map pane, and which one is open is the Mac's.
  ...CANVAS_CATALOG_TOOL_NAMES,
  // The Canvas's edits on the learner's word write that same row on the Mac,
  // and Undo is the Mac's.
  ...CANVAS_EDIT_TOOL_NAMES,
  // Sensemaking (docs/sensemaking-design.md): Ask the Canvas draws its
  // proposals on the Mac's Canvas, Memory on the Canvas reads the Mac's card
  // schedules, and an Atlas and a source's reading levels are written from
  // the Mac's library and kept in its local store.
  "ask_canvas",
  "make_cards_from_canvas",
  "get_canvas_memory",
  "make_atlas",
  "get_atlas",
  "list_atlases",
  "delete_atlas",
  "get_source_levels",
  // Notes as a graph (docs/notes-graph-design.md): the graph is read from the
  // Docs' Markdown on the Mac, and a daily note is a Doc in its library, as
  // is a quarter's or a week's plan.
  "get_linked_references",
  "get_block",
  "get_daily_note",
  "append_to_daily_note",
  "get_plan",
  // A team is a CloudKit zone in its owner's iCloud, projected into the Mac's
  // own SQLite together with its roster and its task board. Creating a team
  // means creating that zone and its zone-wide share, and sharing into one
  // copies rows and files under team-scoped ids through the app's own storage
  // layer. The hosted account reads the learner's private Knowledge zone and
  // nothing else: it has no team zones, no shared database, and no roster, so
  // there is no hosted stand-in for any of these.
  "list_teams",
  "create_team",
  "share_with_team",
  // A notebook's Share… in one call: the team made or found, the notebook
  // copied into it, and the link opened, all by the app (decision 22).
  "share_notebook",
  "list_notebook_tasks",
  "create_notebook_task",
  "update_notebook_task",
  "delete_notebook_task",
  // Assignments live on a team's board (docs/family-design.md): the same team
  // zones and roster the hosted account does not have.
  "assign_to_member",
  "list_assignments",
  "request_share",
  "list_share_requests",
  "fulfil_share_request",
  "decline_share_request",
  // The learner's day is the Mac's Calendar, read and written through the
  // calendar access macOS gave ForeverLM on that Mac; the hosted account has
  // no calendar, and an event an assistant adds has to be in the Calendar app
  // and the Now chip at once. The day's log of what the learner actually did
  // is the Mac's own record, kept beside it.
  "get_calendar_events",
  "create_calendar_event",
  "update_calendar_event",
  "delete_calendar_event",
  "get_day_activity",
  "delete_day_activity",
  // The bout timer and its write-up are the Mac's own day record, and the
  // break it earns has to start counting down in front of the learner at once.
  "get_learning_bout",
  "start_learning_bout",
  "end_learning_bout",
  "write_up_learning_bout",
  "set_learning_bout_break",
  "abandon_learning_bout",
  // A meeting series' schedule and the action items read out of its
  // sessions' transcripts are rows of the Mac's own store, beside the series.
  "set_meeting_schedule",
  "list_meeting_action_items",
  "set_meeting_action_item_done",
]);
