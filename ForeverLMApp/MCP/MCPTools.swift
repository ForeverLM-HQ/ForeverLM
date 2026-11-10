import Foundation
import ImageIO
import OSLog
import PDFKit
import SQLite3


// MARK: - Tool Definition

struct MCPToolDef {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

extension MCPToolDef {
    /// Arguments that only mean something to a caller with no session of its own.
    /// In-app Chat already owns the review session its tool calls bind to.
    static let hostOwnedSessionArguments: Set<String> = ["operation_id"]

    /// The schema in-app Chat advertises: the remote schema minus the arguments the
    /// host already answers for. Offering them would invite the model to supply a
    /// value the app then has to ignore.
    var inAppInputSchema: [String: Any] {
        guard var properties = inputSchema["properties"] as? [String: Any] else { return inputSchema }
        let removed = Self.hostOwnedSessionArguments.filter { properties.removeValue(forKey: $0) != nil }
        guard !removed.isEmpty else { return inputSchema }
        var schema = inputSchema
        schema["properties"] = properties
        if let required = schema["required"] as? [String] {
            schema["required"] = required.filter { !removed.contains($0) }
        }
        return schema
    }
}

/// Clamp a model-supplied 0...1 score or severity so a hallucinated or out-of-range
/// value (e.g. 4.0 or -1) can never be persisted. Applied at the MCP tool boundary.
func clampUnitInterval(_ value: Double) -> Double { min(max(value, 0), 1) }
func clampUnitInterval(optional value: Double?) -> Double? { value.map { min(max($0, 0), 1) } }

// MARK: - MCP Tools Registry

/// How an MCP tool holds the cached SQLite connection while it runs.
enum MCPStoreOperationMode: Sendable {
    /// The tool only reads the cached connection. Any number of readers hold the
    /// gate together: a reader leaves no uncommitted rows for another to see.
    case shared
    /// The tool writes through the cached connection and holds the gate alone.
    case exclusive
}

/// The store gate as the running task holds it: set by the dispatcher for a
/// gated tool's whole run and by `MCPDataStore.withStoreGate` for one
/// stretch, so a stretch nested inside a hold runs under it rather than
/// queuing behind itself. A task spawned inside a hold inherits it; the hold
/// ends when its holder releases the gate, so a task that outlives it takes
/// the gate itself.
final class MCPStoreGateHold: @unchecked Sendable {
    @TaskLocal static var current: MCPStoreGateHold?

    let mode: MCPStoreOperationMode
    private let lock = NSLock()
    private var ended = false

    init(_ mode: MCPStoreOperationMode) {
        self.mode = mode
    }

    var isHeld: Bool { lock.withLock { !ended } }

    func end() {
        lock.withLock { ended = true }
    }
}

/// Readers-writer gate for every MCP operation against the one cached SQLite
/// connection. `KnowledgeStore` uses multi-statement BEGIN/COMMIT boundaries;
/// FULLMUTEX protects individual SQLite calls but does not stop another Task's
/// read from observing uncommitted rows between those calls. Only a writer can
/// leave such rows behind, so readers share the connection and a writer holds
/// it alone. Until 2026-09-18 every tool held it alone, and a `list_teams`
/// waited half a minute behind a `publish_site` that spent the time uploading.
///
/// Admission is FIFO. A writer that arrives while readers hold the gate waits
/// for them; readers that arrive behind that writer wait for it. A stream of
/// reads therefore cannot starve a write, and a later read cannot jump a write
/// that was already queued.
private actor MCPKnowledgeStoreOperationGate {
    private var sharedHolders = 0
    private var exclusiveHeld = false
    private var waiters: [(mode: MCPStoreOperationMode, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire(_ mode: MCPStoreOperationMode) async {
        if waiters.isEmpty, canAdmit(mode) {
            admit(mode)
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((mode, continuation))
        }
    }

    func release() {
        if exclusiveHeld {
            exclusiveHeld = false
        } else {
            sharedHolders = max(0, sharedHolders - 1)
        }
        while let next = waiters.first, canAdmit(next.mode) {
            waiters.removeFirst()
            admit(next.mode)
            next.continuation.resume()
        }
    }

    private func canAdmit(_ mode: MCPStoreOperationMode) -> Bool {
        switch mode {
        case .shared: return !exclusiveHeld
        case .exclusive: return !exclusiveHeld && sharedHolders == 0
        }
    }

    private func admit(_ mode: MCPStoreOperationMode) {
        switch mode {
        case .shared: sharedHolders += 1
        case .exclusive: exclusiveHeld = true
        }
    }
}

/// All MCP tool definitions and their handlers.
/// Reads/writes directly to the local knowledge.db plus synced file storage.
final class MCPToolRegistry: @unchecked Sendable {
    static let shared = MCPToolRegistry()
    private let logger = Logger(subsystem: "ForeverLM", category: "MCPTools")
    private let store: MCPDataStore
    /// Calls in flight by what they ask for (`repeatedCallKey`), so the same
    /// call made again while it runs waits for it. One per registry, as the
    /// store is: every caller in the app goes through `shared`.
    let repeatedCalls = MCPRepeatedCalls<ToolCallOutcome>()

    init(store: MCPDataStore = MCPDataStore()) {
        self.store = store
    }

    /// The picture object `save_course_quiz` and `set_course_quiz_picture`
    /// take (`CourseQuizPicture.parse`): a source's picture, an image in the
    /// store, or a brief for ForeverLM to draw.
    static var courseQuizPictureSchema: [String: Any] {
        [
            "type": "object",
            "description": "The picture the question is shown with: give one of image, image_id, at, page or brief.",
            "properties": [
                "image": ["type": "string", "description": "The Markdown image line (or its foreverlm://image address) that show_source_image returned for a lecture's frame or a reading's page, after you looked at it and cropped it; or that generate_image, save_image or list_images returned for an image in ForeverLM's store."],
                "image_id": ["type": "string", "description": "Instead: an image in ForeverLM's store by the image_id generate_image, save_image or list_images gave — drawn by ForeverLM, or made in ChatGPT, Claude or another app and kept with save_image. Its latest version is shown."],
                "at": ["type": "string", "description": "Instead: a time in the question's source video, seconds (265) or 4:25; the frame on screen then."],
                "page": ["type": "integer", "minimum": 1, "description": "Instead: a page of the question's source (a reading's PDF), counted from 1 within the source; crop it to the figure."],
                "crop": [
                    "type": "object",
                    "description": "With at or page: the part of the frame or page to show, as fractions of it from its top-left corner.",
                    "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
                    "required": ["x", "y", "width", "height"],
                ] as [String: Any],
                "brief": ["type": "string", "description": "Instead: what a picture ForeverLM draws for the question must show — the one idea it makes visible, what is drawn and how the parts relate, the few things labelled — with no invented data; add_course_quiz_pictures draws it on the learner's image model. With image_id, what that picture was made from."],
                "caption": ["type": "string", "description": "What the picture shows, in a few words that do not give the answer away."],
                "show_with": ["type": "string", "enum": ["question", "answer"], "description": "question: above the question, the learner needs it to answer. answer: shown with the grade, because it shows the answer."],
            ] as [String: Any],
            "required": ["show_with"],
        ]
    }

    static func cardImagesInputSchema(description: String) -> [String: Any] {
        [
            "type": "array",
            "maxItems": MemoryCard.maximumImagesPerFace,
            "description": description + " Each entry is the exact Markdown image line a ForeverLM image tool returned, or an object with its target and alt text. One entry per face may be a saved animation (from save_animation or list_animations), by its foreverlm-site://<animation_id>/ address: the card plays it inline with its own controls, on the back only once the back shows.",
            "items": [
                "type": ["string", "object"],
                "properties": [
                    "target": ["type": "string", "description": "A foreverlm://image source or generated-image address, or a saved animation's foreverlm-site://<animation_id>/ address."],
                    "alt": ["type": "string", "description": "A short accessible description of the picture."],
                ],
                "required": [] as [String],
            ] as [String: Any],
        ]
    }

    /// A card's other sources: `{source_id, quote}` each, for `also_from`.
    static func cardAlsoFromInputSchema(description: String) -> [String: Any] {
        [
            "type": "array",
            "maxItems": MemoryCard.maximumLinkedSources,
            "description": description,
            "items": [
                "type": "object",
                "properties": [
                    "source_id": ["type": "string", "description": "Another source the card also stands on, from list_sources, a search or find_card_sources."],
                    "quote": ["type": "string", "description": "The passage of that source that states what the card asks, copied word for word from its text (get_source_content)."],
                ],
                "required": ["source_id", "quote"],
            ] as [String: Any],
        ]
    }

    // MARK: - Tool List

    var tools: [MCPToolDef] {
        let definitions = [
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
                description: "Read AI Usage › API keys: whether the learner has stored their own OpenRouter key, which router it is for, and the key's last four characters. Never the key itself. ForeverLM's AI features are bring your own key: with a key stored, OpenRouter bills the learner directly, at cost, for everything ForeverLM sends through it, and ForeverLM adds nothing. OpenRouter is the only supported provider. The key runs for every signed-in account, paid or not. The response names the scope: an OpenRouter key covers chat, reviews and background tasks plus every voice, speech-to-text, image and video model OpenRouter serves, first-party ones such as Gemini and Grok speech, GPT-4o mini transcription and Veo included, so the key pays for every model ForeverLM uses.",
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
                description: "List a Notebook's tasks with every field: status (todo, doing, done), notes, due date, assignee, and the source or Doc a task is about. When the Notebook is a team's, the response also carries the team and its roster so a member's name can be resolved to the user_record_name an assignee carries. A personal Notebook's tasks have no assignee.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "status": ["type": "string", "enum": ["todo", "doing", "done"], "description": "Only tasks in this status."],
                        "assignee": ["type": "string", "description": "Only tasks assigned to this member: a user_record_name from the team roster, or \"me\" for this account. Team Notebooks only."],
                    ],
                    "required": ["notebook_id"],
                ]
            ),
            MCPToolDef(
                name: "create_notebook_task",
                description: "Add a task to a Notebook's board. In a team Notebook the task is the team's and can be assigned to a member by user_record_name (or \"me\"); every member sees it. In a personal Notebook it is the learner's own and takes no assignee. Refused when the Notebook's team is read-only for this account.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Notebook ID from list_notebooks."],
                        "title": ["type": "string", "description": "What is to be done."],
                        "notes": ["type": "string", "description": "Optional detail."],
                        "status": ["type": "string", "enum": ["todo", "doing", "done"], "description": "Defaults to todo."],
                        "assignee_record_name": ["type": "string", "description": "Team Notebooks only: a member's user_record_name from list_teams or list_notebook_tasks, or \"me\" for this account."],
                        "due_date": ["type": "string", "description": "Optional due date, YYYY-MM-DD."],
                        "source_id": ["type": "string", "description": "Optional source the task is about."],
                        "doc_id": ["type": "string", "description": "Optional Doc the task is about."],
                    ],
                    "required": ["notebook_id", "title"],
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
                name: "get_family_plan",
                description: "Family plans: for each team, whether this account's plan covers its members (family_plan), and for each member whether their Mac has joined and whether they have an OpenRouter key; and membership, when another account's plan covers this one. A covered member's AI runs on an OpenRouter key the owner connected for them, billed to the owner's OpenRouter account.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            MCPToolDef(
                name: "set_family_plan",
                description: "Turn a team's family plan on or off (team owner only). On needs this account to have paid for ForeverLM itself and makes its payment cover every member of the team; their Macs join by themselves. Off ends the coverage for every member of that team. The same switch as Pay for members' AI in the team's Members settings.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "Team ID from list_teams."],
                        "enabled": ["type": "boolean"],
                    ],
                    "required": ["team_id", "enabled"],
                ]
            ),
            MCPToolDef(
                name: "connect_family_member_key",
                description: "Make an OpenRouter key for one member of a family team and hand it to their Mac. Opens OpenRouter's sign-in in the browser on this Mac; the learner finishes it there and this call waits for it (up to five minutes). The key is sealed to the member's device, so only their Mac can open it, and it bills this account's OpenRouter account. The member must have joined the family plan first (get_family_plan).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "team_id": ["type": "string", "description": "Team ID from list_teams."],
                        "member": ["type": "string", "description": "The member's user_record_name or unique display name."],
                    ],
                    "required": ["team_id", "member"],
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
                description: "Read one day's log — what ForeverLM saw the learner actually do, span by span: a paper read in the Reader (reading, listening, watching, with source_id), a chat had (chat, with chat_id) or a Doc written (doc, with doc_id), each with activity_id, start, end, duration_minutes and a foreverlm:// link that opens it; and time the learner drifted off a bout's or a calendar block's goal (off_track, with off_track_to, the site or app's bundle id they drifted to, and no link; only with Nudge Me Back on Track on, get_day_settings); on today a span still going is marked ongoing and runs to now. Also logged_minutes by kind, the day's learning bouts with their write-ups, and minutes_learned, with the day's weekday and relative_day. The log is observation, the Activity pane's; nothing here changes it but delete_day_activity. Read it beside get_calendar_events to see what a day planned for actually went to.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD, \"today\" or \"tomorrow\". Defaults to today on the learner's Mac."],
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
                    "required": [],
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
                    "required": [],
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
                        "artifact_id": ["type": "string", "description": "Optional id of the Doc, Site or animation this Goal is for — the deliverable itself, e.g. the site behind 'Make a site of the rare mitochondrial diseases' (from list_docs, list_animations or a save_site result). The Goals tab opens it from the row. Refused when no record has the id."],
                    ],
                    "required": ["title", "end_date"],
                ]
            ),
            MCPToolDef(
                name: "list_goals",
                description: "List the learner's timebound Goals (deadline, days remaining, approved/completed source counts, review status, and the Doc, Site or animation each is for, as `artifact`). Omit notebook_id to list every Goal, tagged to a Notebook or standing alone; pass it to scope to one Notebook. Notebooks themselves are listed with list_notebooks.",
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
                        "artifact_id": ["type": "string", "description": "The Doc, Site or animation this Goal is for, by id (from list_docs, list_animations or a save_site result): the Goals tab opens it from the row. Pass an empty string to unlink. Refused when no record has the id."],
                    ],
                    "required": ["goal_id"],
                ]
            ),
            MCPToolDef(
                name: "reorder_goals",
                description: "Put the learner's Goals in an order — the drag of a row in the Goals tab. goal_ids may be a subset: the listed Goals are placed first in the given order, and every other open Goal follows in the order it already reads (placed Goals, then the rest by deadline), so reordering three never scrambles the rest. Pass an empty list to forget every placement and read by deadline again. The order drives the Goals tab and list_goals. Each id must name an open timebound Goal (from list_goals); a Notebook, a finished Goal or an unknown id is refused and nothing changes. Confirm the order with the learner before calling this.",
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
                description: "Permanently delete one timebound Goal — the app's Delete on a row of the Goals tab. The Goal's record, its source pool and its Schedule tags go; the sources stay in the library, and a chat started from the Goal stays in Chats with the link cleared. Refused for a Notebook (delete_notebook takes those, with their Goals). Not undoable; to put a Goal away and keep it, use update_learning_goal with status archived instead. Confirm with the learner first.",
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
                name: "list_skills",
                description: "List the learner's skills. A skill is instructions the learner wrote for one kind of work, in the shape of a SKILL.md: a name (typed as /name in ForeverLM's chat), a description saying when it applies, and markdown instructions. Returns each skill's id, name and description, not its instructions; read those with get_skill.",
                inputSchema: [
                    "type": "object",
                    "properties": [String: Any](),
                ]
            ),
            MCPToolDef(
                name: "get_skill",
                description: "Read one of the learner's skills in full: its instructions, and the same skill as a SKILL.md file. Call it when a request matches a skill's description, before starting the work, then do the work the way the skill says. Pass the name (with or without the leading /) or the skill_id from list_skills.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "The skill's name, e.g. \"paper-walkthrough\"."],
                        "skill_id": ["type": "string", "description": "Skill ID from list_skills. Takes precedence over name."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "save_skill",
                description: "Write a skill into ForeverLM. Without skill_id it creates one and needs name, description and instructions (or skill_markdown, a whole SKILL.md whose frontmatter gives the name and description); with skill_id it changes only the fields passed. The name becomes the /command in ForeverLM's chat: lowercase letters, digits and hyphens, and no two skills may share one. The description is what the chat reads to decide when the skill applies, so say when to use it, not only what it does. Write a skill only when the learner asks for one.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "skill_id": ["type": "string", "description": "Skill ID from list_skills, to change an existing skill."],
                        "name": ["type": "string", "description": "Short name, typed after / in the chat."],
                        "description": ["type": "string", "description": "When the skill applies and what it does, in one paragraph (at most 1,024 characters)."],
                        "instructions": ["type": "string", "description": "Markdown: how to do the work."],
                        "skill_markdown": ["type": "string", "description": "A whole SKILL.md (frontmatter with name and description, then the instructions), instead of the three fields. A field passed alongside it wins."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "delete_skill",
                description: "Permanently delete one of the learner's skills. Chats that already used it keep what they were told. Not undoable; confirm with the learner first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "skill_id": ["type": "string", "description": "Skill ID from list_skills."],
                    ],
                    "required": ["skill_id"],
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
                description: "Put existing library sources on a timebound Goal — the app's drop of sources onto a Goal's row on the Goals tab. They join the Goal's approved pool at once (no discovery, no approval step), and a Goal tagged to a Notebook hands them on to that Notebook's pool too. Sources already on the Goal are skipped. Find ids with search_sources_semantic or list_sources; file new material with add_source first. A Notebook is refused — add_notebook_sources takes those. To place the sources on days, follow with assign_sources_to_day.",
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
                name: "list_learning_goals",
                description: "Legacy combined listing of Notebooks and Goals. Prefer list_notebooks for Notebooks and list_goals for timebound Goals.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_completed": ["type": "boolean", "description": "Include records explicitly marked done or archived. Defaults to false."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "daily_review",
                description: "Get today's chat-first daily review plan for a Learning Companion goal — merges open gaps, spaced-repetition due sources, deadline-paced new/review blend, and in-progress reading into one Review Chat session. Does not write to Schedule. With no goal_id, returns a menu of active goals. Pass start_session=false for a read-only briefing (plan + rationale, no session); default starts a linked review session with source content for a live chat review, then call end_review_session when done.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Companion goal ID from list_learning_goals. Omit to get a menu of all active goals."],
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
                        "goal_id": ["type": "string", "description": "Companion goal ID from list_learning_goals. Omit to get a menu of all active goals."],
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
            Self.draftCardsToolDef,
            MCPToolDef(
                name: "save_card_drafts",
                description: "Save flashcards you drafted from the learner's sources as cards for them to check in ForeverLM: they wait in Memory's To Check (a notebook's Studio shows its count on its Cards row) until the learner keeps, edits or skips each one, and only a kept card is ever reviewed. Each card names its source_id, as list_sources or a search returns it (an id the library does not hold refuses the whole call), and a quote: words copied exactly from that source's text (get_source_content), the passage the card stands on. A card whose quote the source does not print is not saved and is listed under not_grounded. A card is about an idea, and an idea is often printed in more than one source: when other sources of the library state what the card asks, name each in also_from with its own quote (at most 5; find_card_sources finds them), and the card stands on all of them, its source chips in To Check and in review showing each. A link whose source's text does not print its quote is left off, the card still saved, and listed under not_grounded_links. Write front as the question to ask, back as the complete answer and no more, and why as one line on why the back is right. A card stands on its own: it is asked weeks later among cards from every source, so neither face may point at its source unnamed (\u{201C}this lecture\u{201D}, \u{201C}the paper\u{201D}, \u{201C}the speaker\u{201D}, \u{201C}the authors\u{201D}); ask about the subject itself, or name the source. Every card is checked for that before it is saved (a small background model call on the learner's Card Wording Check model): one that points at its source is reworded once and listed under reworded, or, when the rewording does not fix it, not saved and listed under not_standalone; when the check cannot run, the source's cards are not saved and sources_not_saved says why. Images are the default: when a relevant slide, paper figure, diagram or other durable ForeverLM picture materially supports recall, include it in front_images or back_images; omit imagery only when no useful picture is available. Each face takes up to four pictures; pass the exact Markdown image line returned by show_source_image, inspect_paper_figure or generate_image, or {target, alt}. Multiple images share a row in review. Local paths, web URLs, chat attachments and made-up image ids are refused. seed is optional: a short, stable key for what the card was drafted from (a walkthrough step, a highlight, a review-guide question), so the same seed is never drafted twice. A card whose seed or front its source's cards already hold is not saved again (already_drafted), whether it was kept or skipped. Pass kept_by_default true when the learner asked you for these cards; leave it false for cards you drafted unasked. Either way the learner keeps, edits or skips each one. A draft waits in To Check until it is kept or skipped; it never expires. Cards stay the learner's own: they never enter a team, whatever notebook they were made for. Returns each source's saved_card_ids and what was not saved, with why.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "cards": [
                            "type": "array",
                            "description": "The cards, one object each, at most 100 in a call.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "source_id": ["type": "string", "description": "The source the card is about, from list_sources or a search."],
                                    "front": ["type": "string", "description": "The question to ask, on one line."],
                                    "back": ["type": "string", "description": "The complete answer, and no more."],
                                    "why": ["type": "string", "description": "One line on why the back is right."],
                                    "quote": ["type": "string", "description": "The passage of the source the card stands on, copied word for word from its text."],
                                    "also_from": Self.cardAlsoFromInputSchema(description: "The other sources the card also stands on, when they state what it asks: each with the passage that does, copied word for word from its text."),
                                    "seed": ["type": "string", "description": "A short, stable key for what the card was drafted from, so it is never drafted twice."],
                                    "front_images": Self.cardImagesInputSchema(description: "Pictures shown with the question before reveal. Include a relevant durable image by default when it materially supports recall."),
                                    "back_images": Self.cardImagesInputSchema(description: "Pictures shown with the answer after reveal. Include a relevant durable image by default when it materially supports recall. Two or more appear side by side when space allows."),
                                ],
                                "required": ["source_id", "front", "back", "quote"],
                            ],
                        ],
                        "kept_by_default": ["type": "boolean", "description": "true when the learner asked for these cards. Defaults to false: drafted unasked."],
                    ],
                    "required": ["cards"],
                ]
            ),
            MCPToolDef(
                name: "list_cards",
                description: "List the learner's Memory cards in ForeverLM. status to_check (the default) lists the cards waiting in Memory's To Check: drafts not yet kept or skipped (kind draft, offered until kept or skipped) and the Memory items from before cards, offered once (kind from_before, kept already), each with card_id, source_id, source_title, front, back, why, optional front_images/back_images, quote, origin and kept_by_default; sources lists every source the card stands on, its own first, each with source_id, source_title and the quote it stands on there (a card often stands on several). status kept lists the kept cards, each with card_id, item_id, ask (the wording to ask: the learner's own rewording when there is one), back, why, optional images, source_ids, sources (each with its quote) and where its schedule stands (new, due, or scheduled with next_due_at). status all lists both. notebook_id narrows to one Notebook's cards (those on its sources) and source_id to the cards that stand on that source, whichever it is of theirs. With to_check or all, drafting says what Make Cards and draft_cards drafted lately for those sources: each run's state and, once done, the card ids it added, the cards it did not find in their source (not_grounded) and the sources it read as excerpts (sampled). Reads only: keep or skip cards with triage_cards.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["to_check", "kept", "all"], "description": "Which cards: to_check (the default), kept, or all."],
                        "notebook_id": ["type": "string", "description": "Only this Notebook's cards, from list_notebooks."],
                        "source_id": ["type": "string", "description": "Only the cards on this source."],
                        "limit": ["type": "integer", "description": "Most cards listed of each status (default 100, max 500)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "list_source_card_coverage",
                description: "List the sources of the learner's library with how many cards each has, as the Library's No Cards list does. The learner's goal is at least one card for each source, and every source worth its weight. The learner writes each source's card themselves, in their own words, in the app (Write Card opens the source with a blank card beside it): the effort is the point. Do not draft cards for these sources, and do not offer to, unless the learner explicitly asks you to; then save_card_drafts with cards you draft yourself (draft_cards only when they ask for ForeverLM's model). You may go through the list with them: name the sources still without a card, open one with open_in_app (kind source) for them to write its card, or quiz them on it. Not Worth Keeping: remove_source, only when the learner says so. scope without_cards (the default) lists the sources no card covers; all lists every source. Each source has source_id, title, source_type, date_added, status (none, to_check, kept or retired) and cards (kept cards). notebook_id narrows to one Notebook's sources. Also returns without_cards and total over that scope. Sources kept from AI, archived, still fetching, paywalled, without text or a team's copy are not listed. Reads only; free.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "scope": ["type": "string", "enum": ["without_cards", "all"], "description": "without_cards (the default) or all."],
                        "notebook_id": ["type": "string", "description": "Only this Notebook's sources, from list_notebooks."],
                        "limit": ["type": "integer", "description": "Most sources listed (default 100, max 500)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "find_card_sources",
                description: "Find the other sources of the learner's library that also state what a card asks, so the card can stand on every source that prints it. A card is about an idea, and an idea is often printed in several sources (a talk and the paper behind it, two lectures on one mechanism); a card that stands on several sources shows each in To Check and in review. Pass card_id (a card to check or a kept card, from list_cards), or a question and an answer you are about to save with save_card_drafts. Returns the passages of other sources nearest the card, up to 4, each with source_id, source_title and passage: they are retrieved, not judged, so read each and keep only those that state the card's answer in substance, not merely its topic, then name them in also_from (source_id and a quote copied word for word from its passage) in save_card_drafts, or in triage_cards when the learner keeps the card. source_ids or notebook_id narrow the search to those sources or to one Notebook's; sources the card already stands on, and sources kept from AI, are never listed. Reads only; free apart from the embedding of the card's words.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "card_id": ["type": "string", "description": "A card_id from list_cards (status to_check or kept)."],
                        "question": ["type": "string", "description": "With answer, instead of card_id: the question of a card you are about to save."],
                        "answer": ["type": "string", "description": "With question: its answer."],
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Look only among these sources, as list_sources or a search returns them.",
                        ],
                        "notebook_id": ["type": "string", "description": "Look only among this Notebook's sources (list_notebooks)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "triage_cards",
                description: "Go through the learner's cards to check, as Memory's To Check does, and only on the learner's word: each decision is theirs. action keep makes a card a Memory card, first asked the day after it is kept; keep with front, back, why, front_images or back_images keeps it with those changes (Edit, then Keep). Image arrays replace that face's pictures and [] removes them. also_from (draft cards only) chooses the other sources the card is kept on, replacing the ones it was drafted with: [] keeps it on its own source alone, and a list keeps it on each source named with its quote, copied word for word from that source's text (a source whose text does not print its quote refuses the keep). A kept card stands on those sources for good; changing them later means starting the card over. For a card from before cards (kind from_before), which is kept already, a new front alone rewords it, and a new back, why or image list starts it over as a new card. action skip drops a draft for good, so its seed is never drafted again, and retires a card from before cards, never asked again. decisions name cards by the card_id list_cards returned; keep_source_ids and skip_source_ids keep or skip every card to check on those sources at once. Returns what was kept (with item_id), skipped, refused (with why) and not found (decided already, expired, or not a card to check), and how many cards still wait.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "decisions": [
                            "type": "array",
                            "description": "One decision per card.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "card_id": ["type": "string", "description": "A card_id from list_cards status to_check."],
                                    "action": ["type": "string", "enum": ["keep", "skip"], "description": "keep or skip."],
                                    "front": ["type": "string", "description": "With keep: the question in the learner's words."],
                                    "back": ["type": "string", "description": "With keep: the answer in the learner's words."],
                                    "why": ["type": "string", "description": "With keep: why the answer is right, in the learner's words."],
                                    "front_images": Self.cardImagesInputSchema(description: "With keep: pictures shown with the question; pass [] to remove them."),
                                    "back_images": Self.cardImagesInputSchema(description: "With keep: pictures shown with the answer; pass [] to remove them."),
                                    "also_from": Self.cardAlsoFromInputSchema(description: "With keep, on a draft: the other sources to keep the card on, replacing those it was drafted with; [] keeps it on its own source alone."),
                                ],
                                "required": ["card_id", "action"],
                            ],
                        ],
                        "keep_source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Keep every card to check on these sources.",
                        ],
                        "skip_source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Skip every card to check on these sources.",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_due_cards",
                description: "Today's card review in ForeverLM, for you to run here: the learner's kept cards to ask today, in the order the app's own card review asks them (the cards of a notebook with a block on today's calendar or a Goal ending within 36 hours first, then the cards kept yesterday, new today, then due cards most overdue first, then the other new cards, up to the day's new_cards_per_day in all), cut to the learner's daily minutes, across every Notebook or narrowed to one with notebook_id. Each card has item_id, card_id, ask (the wording to ask exactly as written: the card's question, the learner's own rewording, or, once it has been remembered twice, a rewording ForeverLM checked asks for the same answer), back, why, optional front_images/back_images, source_id, source_title, quote, sources (every source the card stands on, each with its quote), is_new, and say_first when it is asked in other words for the first time. Show front_images with the question; ask one card at a time and show nothing of its back, back_images, why or quote before the learner has answered it in their own words, typed or said: never a bare \u{201C}show me\u{201D}, never an answer you supply for them (an \u{201C}I don't know\u{201D} is an answer, and counts as forgot). Then show back_images beside the answer and record each answer with record_card_result and the sitting_id returned here. due_left_over and new_left_over count what the day's minutes leave for another day. Reads only: a card listed is not marked asked.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Only this Notebook's cards (those on its sources), from list_notebooks."],
                        "limit": ["type": "integer", "description": "Most cards listed (default and max 200)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "record_card_result",
                description: "Record the learner's answer to one kept card, as ForeverLM's card review does when they press Forgot or Remembered: a self-graded attempt with the wording asked as its question, which moves the card's schedule. Pass card_id (or item_id) as get_due_cards or list_cards returns it, remembered (your judgment of the answer the learner gave in their own words, against the card's back, told to them in a line saying what was missing — as ForeverLM's Check does — or the learner's own say when they overrule you; false when they did not know), asked (the wording you asked; the card's ask by default) and the sitting_id get_due_cards returned. Storage decides what counts: one answer per card per sitting (another is already_recorded), only for a card that is due, or new and eligible (any other answer is not_counted: an early answer never stretches an interval), and never for a retired card. practice true is for practice the learner asked for outside today's review: a new card then counts even on the day it was kept, and a card seen before still counts only when due. A card still to check is refused: it is kept with triage_cards first, on the learner's word. Returns outcome (recorded, already_recorded, not_counted or retired) and when the card is next asked.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "card_id": ["type": "string", "description": "A card_id from get_due_cards or list_cards."],
                        "item_id": ["type": "string", "description": "The card's item_id, instead of card_id."],
                        "remembered": ["type": "boolean", "description": "true when the learner remembered the card, false when they forgot it."],
                        "asked": ["type": "string", "description": "The question exactly as you asked it. Defaults to the card's ask."],
                        "sitting_id": ["type": "string", "description": "The sitting_id get_due_cards returned. Without it, the day's answers over MCP are one sitting."],
                        "practice": ["type": "boolean", "description": "true when the learner asked to practise cards outside today's review. Defaults to false."],
                    ],
                    "required": ["remembered"],
                ]
            ),
            MCPToolDef(
                name: "practice_cards",
                description: "Open ForeverLM's own card review on the learner's Mac over kept cards you chose: the way to review some of the cards \u{2014} a topic (\u{201C}show me my cards on mitochondria\u{201D}), a source, a set \u{2014} rather than today's review. Read list_cards status kept and choose the cards by what each one asks, not by a word in it; pass their card_ids and a title saying what they are about. The review takes the window the learner last used and brings ForeverLM to the front, as practice they asked for: the due and new cards among them first, whose answers count, then the ones not due yet, whose answers never move their schedule. The learner answers each card there, typed or said, and the app checks it; nothing is asked in this chat. Returns how many cards were dealt (due_or_new, not_due_yet) and not_found for any card_id no kept card answers to. Refused while a card review already has that window. Needs a Studio window open.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "card_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "The card_id of each kept card to practise, from list_cards status kept (at most 500).",
                        ],
                        "title": ["type": "string", "description": "What the cards are about, in a few words (Mitochondria)."],
                    ],
                    "required": ["card_ids", "title"],
                ]
            ),
            MCPToolDef(
                name: "update_card",
                description: "Change one of the learner's kept cards, as Memory's All Cards does, and only on the learner's word. front alone rewords the card: it is asked in the new words from then on, its schedule untouched (the words it was kept with clear the rewording). A new back, why, front_images or back_images, or start_over true, starts the card over: the old card is retired with its answers and a new card is kept on the same passages, first asked the next day, returned as card_id beside previous_card_id. Image arrays replace that face's pictures and [] removes them. always_ask true asks the card in its own words every time, never a rewording; false lets its wording vary again. retire true retires the card, never asked again, its answers kept; it takes no other change. Pass card_id (or item_id) as get_due_cards or list_cards status kept returns it; a card still to check is changed with triage_cards, except that front_images or back_images alone, with the card_id of a card in Memory's To Check, put pictures on it without deciding it, whether or not it is on screen: they are saved with the card, its words are untouched, and the learner's Keep carries them (Skip drops them). New words are checked first, as save_card_drafts checks a draft: words that point at the source unnamed (\u{201C}this lecture\u{201D}, \u{201C}the paper\u{201D}) are reworded once (the message says so), or the change is refused with the reason. Returns the card's card_id, item_id, ask and always_ask after the change.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "card_id": ["type": "string", "description": "A card_id from get_due_cards or list_cards status kept."],
                        "item_id": ["type": "string", "description": "The card's item_id, instead of card_id."],
                        "front": ["type": "string", "description": "The question in the learner's new words."],
                        "back": ["type": "string", "description": "A new answer: starts the card over."],
                        "why": ["type": "string", "description": "A new line on why the answer is right: starts the card over."],
                        "front_images": Self.cardImagesInputSchema(description: "Replacement pictures for the question face; starts the card over. Pass [] to remove them."),
                        "back_images": Self.cardImagesInputSchema(description: "Replacement pictures for the answer face; starts the card over. Pass [] to remove them."),
                        "start_over": ["type": "boolean", "description": "Start the card over as it is asked now: a new card, first asked tomorrow."],
                        "always_ask": ["type": "boolean", "description": "true: always ask it in its own words; false: let its wording vary again."],
                        "retire": ["type": "boolean", "description": "Retire the card: never asked again."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "list_practices",
                description: "The learner's study practices: each with practice_id, title (the practice in one sentence), why, status (proposed, adopted, dismissed or retired), origin (rule: found in the learner's history by ForeverLM; user: set by the learner; ai: suggested by an assistant), rule (what the card queue, drafting and the tutor follow once it is adopted: {kind, params}), setting_change when adopting it changes a Setting, the evidence and minimum sample behind a rule's proposal, and when it was decided. status narrows the list. ForeverLM's own rules are off until they are signed off (engine.proposes), so practices come from set_practice for now. Needs the Mac on ForeverLM's new iCloud sync. Reads only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["proposed", "adopted", "dismissed", "retired"], "description": "Only the practices with this status."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "decide_practice",
                description: "Adopt, dismiss or retire a study practice, on the learner's word. Adopting one that carries a setting_change applies it as that setting's own tool does (new cards a day through set_memory_review_settings) and records when (setting_applied). The decision follows the learner to their other devices, and a later proposal of the same practice never undoes it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "practice_id": ["type": "string", "description": "The practice, from list_practices."],
                        "decision": ["type": "string", "enum": ["adopt", "dismiss", "retire"], "description": "adopt, dismiss or retire."],
                    ],
                    "required": ["practice_id", "decision"],
                ]
            ),
            MCPToolDef(
                name: "set_practice",
                description: "Write a study practice. Without practice_id it makes a new one: the learner's own, adopted at once, or with suggested true an assistant's suggestion, proposed for the learner to adopt or dismiss. With practice_id it changes that practice's title, why, rule, scope or status. rule is {kind, params}, kind one of reviewWindow, interleave, retrievalAfterReading, draftSeeds, newCardsPerDay or walkAfterReading. scope is all (the default), nb:<notebook id>, crs:<course id> or type:<source type>. A practice is the learner's own and never enters a team. Needs the Mac on ForeverLM's new iCloud sync.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "practice_id": ["type": "string", "description": "The practice to change, from list_practices. Omit to make a new one."],
                        "title": ["type": "string", "description": "The practice in one sentence, as the learner would say it."],
                        "why": ["type": "string", "description": "Why it helps, in a few sentences (at most 4 KB)."],
                        "rule": ["type": "object", "description": "What follows it once adopted: {kind, params}."],
                        "status": ["type": "string", "enum": ["proposed", "adopted", "dismissed", "retired"], "description": "Its status."],
                        "scope": ["type": "string", "description": "all, nb:<notebook id>, crs:<course id> or type:<source type>."],
                        "suggested": ["type": "boolean", "description": "True for an assistant's suggestion the learner has not agreed to: it waits as proposed. Defaults to false."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "set_review_depth",
                description: "Set how much of a memory review one source (source_id) or a whole kind of source (source_type, e.g. podcast) gets by default: quick is the contour only, standard adds a probe or two, deep works the full plan. Call it when the learner says so — \"keep podcasts quick\" — and confirm in half a sentence. Depth never skips the contour.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "depth": ["type": "string", "enum": ["quick", "standard", "deep"], "description": "quick, standard, or deep."],
                        "source_id": ["type": "string", "description": "One source to set. Omit when setting a kind of source."],
                        "source_type": ["type": "string", "description": "A kind of source to set the default for: article, paper, podcast, book, course, meeting, video, xPost."],
                    ],
                    "required": ["depth"],
                ]
            ),
            MCPToolDef(
                name: "record_understanding",
                description: "Close a cohort review. Rewrite what the learner now understands about each source actually discussed — the complete replacement document, compacted, not a patch — and record a short session summary. Only sources the session covered may be written; anything else is rejected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Session ID returned by cohort_review."],
                        "session_summary": ["type": "string", "description": "At most three lines: what was covered, what moved, what to pick up next time."],
                        "updates": [
                            "type": "array",
                            "description": "One entry per source discussed.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "source_id": ["type": "string"],
                                    "understanding_markdown": ["type": "string", "description": "The complete rewritten document about what THIS learner understands. Not a summary of the source."],
                                    "open_thread_count": ["type": "integer", "description": "How many genuinely unresolved threads you left. 0 is normal."],
                                ],
                                "required": ["source_id", "understanding_markdown"],
                            ],
                        ],
                    ],
                    "required": ["session_id", "session_summary", "updates"],
                ]
            ),
            MCPToolDef(
                name: "review_suggested_sources",
                description: "Approve or reject sources that ForeverLM discovered for a Learning Companion goal. Approved sources enter the daily quiz rotation; rejected sources are tombstoned and never suggested again. Use after daily_quiz or list_learning_goals surfaces pending suggestions.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Companion goal ID."],
                        "approve": ["type": "array", "items": ["type": "string"], "description": "Source IDs to approve into the pool."],
                        "reject": ["type": "array", "items": ["type": "string"], "description": "Source IDs to reject (tombstoned)."],
                    ],
                    "required": ["goal_id"],
                ]
            ),
            MCPToolDef(
                name: "add_companion_sources",
                description: "Legacy: add sources from the library to a companion record (a Notebook or a Goal) as approved seeds. Prefer add_notebook_sources for a Notebook and add_goal_sources for a timebound Goal, which check the kind of record they are given. Different from review_suggested_sources, which only approves sources ForeverLM already discovered. Find source IDs with search_sources_semantic (pass exclude_notebook_id so sources already in the goal never come back) or list_sources first. Sources already in the goal are skipped.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "goal_id": ["type": "string", "description": "Companion goal ID."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Library source IDs to add as approved seeds."],
                    ],
                    "required": ["goal_id", "source_ids"],
                ]
            ),
            MCPToolDef(
                name: "search_sources_semantic",
                description: "Search sources by semantic similarity, exact text, source type, and the local calendar day a source was added to the library. The only dates this tool knows are when a source was saved: use added_from/added_to plus source_type for requests about that, such as yesterday's meeting, resolving relative dates against the local date in the chat prompt rather than asking semantic similarity to infer time. There is no publication-date filter, so a work's own year — a 2021 book, a 2019 trial — is never an argument here; put it in query instead and leave added_from/added_to out. Query may be omitted when the added-date or type filters identify the requested sources. This is the required tool for any targeted paper, title, author, keyword, topic, or dated-source lookup. If a result looks plausible but its excerpt does not prove the match, inspect that candidate with get_source_content instead of calling list_sources or immediately widening to the web. Pass notebook_id to search only within one Notebook's approved sources. When looking for sources to ADD to a Notebook, pass exclude_notebook_id instead so sources already attached to that Notebook are filtered out. notebook_id and exclude_notebook_id are mutually exclusive. When the request names a podcast show or YouTube channel (\"which Huberman episodes cover mitochondria\"), pass show so the ranking runs inside that show instead of the whole library; to list every episode or paper matching a show, author or title, use filter_sources.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Natural-language concept or topic query. Carries any publication year the request mentions. Optional when source_type, added_from, or added_to is supplied."],
                        "limit": ["type": "integer", "description": "Maximum number of results to return (default 8)"],
                        "threshold": ["type": "number", "description": "Minimum cosine similarity score from 0.0 to 1.0. Ranking is rank-fused, so leave this at the default 0 unless deliberately filtering; the contextual embedding is anisotropic and unrelated texts still score ~0.8."],
                        "source_type": ["type": "string", "enum": StudioSourceType.searchFamilyNames, "description": "Optional. One family of sources to search; omit it to search the whole library in a single call rather than one family at a time. article covers every saved web page, including manually added and still-unclassified ones. Use meeting for a dated session lookup."],
                        "added_from": ["type": "string", "description": "Optional. Earliest local calendar day the source was SAVED to the library, inclusive, as a full YYYY-MM-DD day. Never a publication year: a bare year is rejected, and a real one would search the wrong axis in silence."],
                        "added_to": ["type": "string", "description": "Optional. Latest local calendar day the source was SAVED to the library, inclusive, as a full YYYY-MM-DD day. Never a publication year: a bare year is rejected, and a real one would search the wrong axis in silence."],
                        "notebook_id": ["type": "string", "description": "Optional explicit Notebook ID. Restricts the search to that Notebook's approved sources. Cannot be combined with exclude_notebook_id."],
                        "exclude_notebook_id": ["type": "string", "description": "Optional explicit Notebook (companion goal) ID. Sources already attached to that Notebook — approved, pending, or rejected — are omitted from the results, and the limit is filled from the remaining candidates. Use this when finding NEW sources to add to a Notebook."],
                        "show": ["type": "string", "description": "Optional podcast show or YouTube channel name (from list_shows; part of the name also works). Restricts the search to that show's episodes."],
                    ],
                    "required": [],
                ]
            ),
            MCPToolDef(
                name: "search_sources_keyword",
                description: "Find every source in the library whose title, author, or text literally contains the given word or phrase. This is a case-insensitive SUBSTRING match, not a topic search and not a tokenized index: \"uncoupler\" finds a paper that only ever says \"uncouplers\", and \"uncouplers\" does not find one that only says \"uncoupler\" — so prefer the shortest stem you actually mean. Results are every match, most mentions first, with passages showing the word in place; read those and drop the irrelevant hits yourself rather than trusting the order. Use this when the learner asks what mentions a specific term, name, gene, drug, or phrase, or wants an exhaustive sweep. Use search_sources_semantic instead when the question is about a topic or concept rather than a spelling. Several keywords are OR by default, which is how you sweep spellings and synonyms in one call; pass match all to require every one of them in the same source. When the question is about particular sources — the papers attached to this chat, \"do these two papers both mention X\" — pass their ids as source_ids so the sweep reads only those; each result lists the mentions of every keyword it holds, and the answer names the keywords no source contains.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "keywords": [
                            "type": "array",
                            "items": ["type": "string"],
                            "maxItems": SourceKeywordSearch.maximumKeywords,
                            "description": "Up to \(SourceKeywordSearch.maximumKeywords) words or phrases, each matched literally as a substring. A phrase matches only where those words appear together in that order. For more, split them across several calls.",
                        ] as [String: Any],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional source IDs (from the sources attached to this chat, list_sources or a search) to restrict the sweep to. Combines with the other scopes."],
                        "match": ["type": "string", "enum": ["any", "all"], "description": "Whether a source must contain any keyword (default) or every one of them."],
                        "limit": ["type": "integer", "description": "Maximum sources to return (default 50, maximum 200). The answer says when more matched."],
                        "snippets_per_source": ["type": "integer", "description": "Passages shown per source (default 2, maximum 5). Use 0 for a bare list of what matched."],
                        "source_type": ["type": "string", "enum": StudioSourceType.searchFamilyNames, "description": "Optional. One family of sources to restrict the sweep to; omit it to sweep the whole library in a single call rather than one family at a time. article covers every saved web page, including manually added and still-unclassified ones."],
                        "notebook_id": ["type": "string", "description": "Optional explicit Notebook ID. Restricts the sweep to that Notebook's approved sources."],
                        "show": ["type": "string", "description": "Optional podcast show or YouTube channel name (from list_shows; part of the name also works). Restricts the sweep to that show's episodes."],
                    ],
                    "required": ["keywords"],
                ]
            ),
            MCPToolDef(
                name: "start_review_session",
                description: "Start a review session on a topic. Returns relevant sources and cards for context, plus a Session ID. Keep that Session ID — you must pass it to end_review_session when the review is done (with the review's questions and answers) to save the review. If reviewing a specific source, pass source_id or source_ids so the completed session is linked to that source. Pass notebook_id only when the learner explicitly asked to review within that Notebook; source_id or source_ids is then required and must belong to the Notebook. Notebook selection is never inherited implicitly. Do not use this for plain summary requests; call get_source_content and summarize directly instead. Begin the chat review by listing a compact, dynamic checklist of core concepts you plan to cover, then ask one deep question at a time.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string", "description": "Topic to quiz on"],
                        "source_id": ["type": "string", "description": "Optional source ID being reviewed"],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional source IDs being reviewed"],
                        "notebook_id": ["type": "string", "description": "Explicit Notebook ID (list_notebooks) or Goal ID (list_goals) to link this review to. Use only when the learner asked to work in that Notebook or on that Goal; requires source_id or source_ids from its approved pool. A review linked to a Goal counts toward it."],
                        "operation_id": ["type": "string", "description": "Optional caller-generated idempotency key. Retry the exact same request with the same key to reuse its session; changed arguments fail closed."],
                    ],
                    "required": ["topic"],
                ]
            ),
            MCPToolDef(
                name: "list_shows",
                description: "List every podcast show and YouTube channel in the library with its episode count, most episodes first. Use it to find a show's exact name before filter_sources or a search's show argument, or when the learner asks which podcasts or channels they have.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["podcast", "youtube", "all"], "description": "Optional. podcast, youtube, or all (default)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "filter_sources",
                description: "List EVERY source whose metadata matches — the exhaustive answer to \"all Huberman Lab episodes\", \"every paper by Martin Picard\", or \"everything with Picard in the title, byline or show\". Filters are case-insensitive substrings over metadata (title, author, show or channel, journal), combined with AND; nothing is ranked or cut off by similarity. Returns each source's id, type, show or author, year, word count and the local date and time it was added, newest first. It is also the answer to \"the latest\", \"the newest\" or \"the last\" source of a kind: \"look at my latest YouTube video\" is source_type video with a small limit, and the first line is the one most recently added (add show for \"the last Huberman episode\"). A ranked search orders by similarity, never by recency, so it cannot answer that. Use this whenever the learner names a show, channel, author or person and wants the complete set; then read the titles, or pass the show to search_sources_semantic or search_sources_keyword to find what those episodes say about a topic. It reads metadata only, not a source's text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "show": ["type": "string", "description": "Podcast show or YouTube channel name, from list_shows; part of the name also works (\"Huberman\")."],
                        "author": ["type": "string", "description": "Text the author or byline contains: a paper's authors, an article's author, a meeting's presenter."],
                        "title_contains": ["type": "string", "description": "Text the title contains."],
                        "text": ["type": "string", "description": "Text any of title, author, show or channel, journal, or book/course/playlist contains — use it for a person who may be a guest in an episode title or an author of a paper (\"Martin Picard\")."],
                        "source_type": ["type": "string", "enum": StudioSourceType.searchFamilyNames, "description": "Optional. One family of sources."],
                        "include_archived": ["type": "boolean", "description": "Also list archived sources (default false)."],
                        "limit": ["type": "integer", "description": "Maximum sources to return (default 200, maximum 1000). The answer says when more matched."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "end_review_session",
                description: "End a review session only after the learner explicitly asks to stop or confirms they want to finish; covering the planned concepts or reaching a question count is not permission to end. Records the score and summary and saves the review with its transcript. Pass the session_id from start_review_session or daily_quiz (the \"Session ID:\" line). If that id is lost, call this anyway with transcript and source_ids — the review is then saved as a completed imported review, never discarded. For daily_quiz sessions, pass any gaps you observed so they carry into future quizzes; source study state updates automatically.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Session ID from start_review_session or daily_quiz. May be empty if lost."],
                        "overall_score": ["type": "number", "description": "Overall understanding score, 0.0 to 1.0."],
                        "summary": ["type": "string", "description": "Short summary of what was covered and how the learner did."],
                        "transcript": ["type": "string", "description": "The review's questions and the learner's answers, in Markdown, as written in this review. Required when session_id is empty."],
                        "chat_export": ["type": "string", "description": "Alias for transcript."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs reviewed. Links and marks them reviewed; required when session_id is empty."],
                        "topic": ["type": "string", "description": "Optional saved title; used only when session_id is empty."],
                        "gaps": [
                            "type": "array",
                            "description": "Optional gaps in understanding observed during the quiz. Each carries forward until resolved.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "summary": ["type": "string", "description": "Short description of the gap, e.g. 'Confuses TRPV4 gating with Ca2+ influx mechanism'."],
                                    "source_id": ["type": "string", "description": "Optional source most related to the gap."],
                                    "severity": ["type": "number", "description": "0.0-1.0 how central to the goal."],
                                    "status": ["type": "string", "enum": ["open", "improving", "resolved"], "description": "Defaults to open."],
                                ],
                                "required": ["summary"],
                            ],
                        ],
                        "memory_attempts": [
                            "type": "array",
                            "description": "Structured evidence from memory_review. For an existing memory_item pass item_id and omit first-review fields. For a new_item omit item_id and pass source_id, semantic_target, rubric, and an exact evidence_excerpt from that source. Omit this array for ordinary reviews and host-bound in-app chats, which record attempts turn by turn.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "item_id": ["type": "string", "description": "Existing-review mode only: exact item_id returned in memory_review.memory_items. Omit for a first review."],
                                    "source_id": ["type": "string", "description": "First-review mode only: exact source_id returned in memory_review.new_items. It must belong to this review session."],
                                    "semantic_target": ["type": "string", "description": "First-review mode only: one stable, source-grounded idea the learner should be able to explain or apply. Keep this target across future varied questions."],
                                    "rubric": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                        "description": "First-review mode only: 1 to 12 compact criteria that distinguish a strong answer. Do not include a fixed question or answer script.",
                                    ],
                                    "evidence_excerpt": ["type": "string", "description": "First-review mode only: a non-empty exact excerpt (20 to 2000 characters) from the canonical source text grounding this target."],
                                    "prompt": ["type": "string", "description": "The question actually asked: a card's `ask` wording as written, otherwise the fresh question you composed."],
                                    "learner_answer": ["type": "string", "description": "The learner's answer verbatim."],
                                    "evaluation": ["type": "string", "description": "Feedback given for this answer."],
                                    "score": ["type": "number", "description": "Model-authored score from 0.0 to 1.0."],
                                    "retrieval_quality": [
                                        "type": "string",
                                        "enum": ["not_recalled", "hinted", "independent"],
                                        "description": "How much retrieval support the learner used; ForeverLM maps this to scheduling deterministically.",
                                    ],
                                    "misconception": ["type": "string", "description": "Optional specific misconception to revisit."],
                                    "missing_rubric_elements": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                        "description": "Rubric elements still missing; use an empty array when none are missing.",
                                    ],
                                ],
                                "required": ["prompt", "learner_answer", "evaluation", "score", "retrieval_quality", "missing_rubric_elements"],
                            ],
                        ],
                    ],
                    "required": ["session_id", "overall_score", "summary"],
                ]
            ),
            MCPToolDef(
                name: "get_review_sessions",
                description: "List past review sessions and chats, optionally filtered by topic or source_id. Each line carries the session's id; the app's Copy Link on a chat gives that same id as foreverlm://chat/<id>, and every tool that takes a session_id accepts the link as given.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string", "description": "Filter by topic (fuzzy match)"],
                        "source_id": ["type": "string", "description": "Filter by source ID (exact match, returns all sessions that reference this source)"],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_review_session_transcript",
                description: "Get the exported chat transcript or recorded exchanges for a review session or chat. The one tool to call when the learner hands you a chat link — foreverlm://chat/<id>, what the app's Copy Link on a chat copies: pass the link as session_id. A chat still in progress in the app returns its turns so far, so call again later for what has been said since.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Review session ID from get_review_sessions, or a chat link of the form foreverlm://chat/<id> exactly as the learner pasted it"],
                    ],
                    "required": ["session_id"],
                ]
            ),
            MCPToolDef(
                name: "import_review_chat",
                description: "Save a review the learner held with another assistant (Claude, ChatGPT or another) in ForeverLM as a completed review. ForeverLM parses the transcript into individual question/answer exchanges that are stored, displayed per-turn, and searchable — no share link needed. Prefix each message with a role label, on its own line or inline ('Assistant:' / 'You:', or '**Claude**' / '**User**'), so turns are detected correctly. Links the review to the given sources, marks them reviewed (unless mark_reviewed is false, which the chat keeps for every later call), and optionally files the chat directly under a Notebook. A chat too long for one call arrives in chunks: import the first chunk without session_id, then pass the id that call returns as session_id with each further chunk, in order, and its turns are appended after the stored ones. A retried chunk identical to the stored tail is not stored twice. When the learner asks for it, the same two calls keep a discussion of their sources as it happens: save the first question and answer without session_id, keep the id, and append each later exchange with it as soon as you have answered — every chat about a source lives in ForeverLM, and it is saved as you go, not when it ends. The stored chat must be the chat the learner saw: in Claude Code, pass transcript_file (the CLAUDE_CODE_SESSION_ID environment variable) instead of transcript, after your answer is written, and ForeverLM reads the turns, their times and their source links from Claude Code's own session file; anywhere else, transcript carries the question and the answer word for word — the markdown and every foreverlm://source link as written, never a summary or a shortened version.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short title for the saved review, e.g. the topic covered. Ignored when session_id is given: the session keeps its title."],
                        "transcript": ["type": "string", "description": "The review's turns with role labels (Assistant/Claude/ChatGPT vs User/You), as the learner saw them — markdown, source links and all. With session_id, only the turns not yet imported. Omit when transcript_file is given."],
                        "transcript_file": ["type": "string", "description": "The assistant's own record of this conversation on the learner's Mac, read in place of transcript so the stored chat is the chat word for word: a Claude Code session id (the CLAUDE_CODE_SESSION_ID environment variable, which names ~/.claude/projects/*/<id>.jsonl) or the path of that file, or the path of a role-labeled text export. A Claude Code session file yields what the learner typed, including messages sent while a turn ran, and every text the assistant showed, each at the time it happened; tool calls, tool results and thinking are left out. Call after your answer is written, so it is in the file. With session_id, the stored chat is made to match the file: turns already stored stay, turns the file has gained are appended, and a stored turn that disagrees with the file is rewritten from it."],
                        "session_id": ["type": "string", "description": "Append mode: the id returned by an earlier import_review_chat call for this same chat. The chunk's turns are appended to that session; any source_ids are added to its sources; summary, overall_score, model_provider and model_id replace the stored values when given. Omit for the first chunk."],
                        "notebook_id": ["type": "string", "description": "Optional: the Notebook (from list_notebooks) or the Goal (from list_goals) to file a first import under; a chat about a Goal's papers belongs on that Goal, where its row and editor list it. Ignored when session_id is given; appended chunks keep the chat's existing home."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Source IDs this review covers. Omitted, the chat is saved with no sources; an appended chunk adds only the ids given here."],
                        "mark_reviewed": ["type": "boolean", "description": "Whether the chat counts its sources as reviewed and marks their Schedule items done. On a first import it defaults to true; pass false for a chat that researched or discussed the sources without reviewing the learner on them — research into what has changed since a textbook was written, for one. The choice is the chat's: with session_id it defaults to what the first import chose, so the sources a later call adds to a chat saved with false stay unreviewed unless that call passes true."],
                        "summary": ["type": "string", "description": "Optional short summary of what was covered and how it went."],
                        "overall_score": ["type": "number", "description": "Optional overall understanding score from 0.0 to 1.0."],
                        "model_provider": ["type": "string", "description": "Optional assistant that ran the review, e.g. 'Claude' or 'ChatGPT'."],
                        "model_id": ["type": "string", "description": "Optional model identifier, e.g. 'claude-opus-5'."],
                        "started_at": ["type": "string", "description": "When the conversation actually ran, ISO 8601 (e.g. 2026-09-18T14:00:00Z). Given with ended_at, the chat is drawn on the day's log (the Activity pane, get_day_activity) at the hours it happened rather than at the minute it was imported, so an hour spent in ChatGPT shows where it was spent. With session_id, the hours of the exchanges this call adds: they are drawn as a span of their own, or joined to the chat's span they continue within \(DayPlan.activityMergeGapMinutes) minutes, so time away between two exchanges is not drawn. Omit when you do not know them: the app never invents an hour it did not see."],
                        "ended_at": ["type": "string", "description": "When the conversation finished, ISO 8601. Must be after started_at. A Claude Code session file supplies the time of every message itself, and the chat is drawn in sittings, split wherever more than \(DayPlan.activityMergeGapMinutes) minutes passed between two messages."],
                    ],
                    "required": ["title"],
                ]
            ),
            MCPToolDef(
                name: "search_review_sessions",
                description: "Search across saved review sessions and their full chat transcripts. Matches session titles, summaries, and the question/answer text of every stored exchange, returning matching sessions with a snippet. Use get_review_session_transcript to read a full match.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text to search for across session titles, summaries, and transcript content."],
                        "limit": ["type": "integer", "description": "Maximum number of sessions to return (default 10)."],
                    ],
                    "required": ["query"],
                ]
            ),
            MCPToolDef(
                name: "list_review_session_links",
                description: "List saved Claude and ChatGPT review session share links.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
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
                name: "set_source_hidden",
                description: "Hide or unhide a source in Studio. For podcast episodes this also updates the podcast episode hide state. Hiding is visual only: the source leaves the Studio sources list and stays in knowledge for chat, search and reviews.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "The source ID"],
                        "hidden": ["type": "boolean", "description": "true to hide, false to unhide"],
                    ],
                    "required": ["source_id", "hidden"],
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
                name: "set_podcast_episode_hidden",
                description: "Hide or unhide a podcast episode source. Hiding is visual only: the source leaves the Studio sources list and stays in knowledge for chat, search and reviews.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Podcast episode source ID"],
                        "hidden": ["type": "boolean", "description": "true to hide, false to unhide"],
                    ],
                    "required": ["source_id", "hidden"],
                ]
            ),
            MCPToolDef(
                name: "set_podcast_show_hidden",
                description: "Hide or unhide all normal episodes for a podcast show by show name. A hidden show is muted: its episodes leave the Studio sources list and are excluded from chat, search, reviews and these tools, except an episode with a visible override (set_podcast_episode_visible_override), which comes back into both.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "show_name": ["type": "string", "description": "Podcast show name as shown in Studio"],
                        "hidden": ["type": "boolean", "description": "true to hide, false to unhide"],
                    ],
                    "required": ["show_name", "hidden"],
                ]
            ),
            MCPToolDef(
                name: "set_podcast_show_import_blocked",
                description: "Block or unblock a podcast show's future imports by show name — Studio's 'Never Import <show>'. A blocked show's episodes are never imported from Apple Podcasts again, however often they are played; episodes already in the library are untouched (use remove_all_from_podcast for those). This is about ingestion, not visibility: use set_podcast_show_hidden to mute a show whose episodes should stay.",
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
                name: "set_podcast_episode_visible_override",
                description: "Show or stop force-showing a podcast episode when its show is hidden. A shown episode is back in the sources list and in knowledge for chat, search and reviews.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "Podcast episode source ID"],
                        "visible": ["type": "boolean", "description": "true to force visible, false to remove the override"],
                    ],
                    "required": ["source_id", "visible"],
                ]
            ),
            MCPToolDef(
                name: "set_youtube_channel_hidden",
                description: "Hide or unhide every YouTube video from an uploader channel. A hidden channel is muted: its videos leave the Studio sources list and are excluded from chat, search, reviews and these tools, except a video with a visible override (set_youtube_video_visible_override), which comes back into both.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "channel_name": ["type": "string", "description": "YouTube channel name as shown in Studio"],
                        "hidden": ["type": "boolean", "description": "true to hide, false to unhide"],
                    ],
                    "required": ["channel_name", "hidden"],
                ]
            ),
            MCPToolDef(
                name: "set_youtube_video_visible_override",
                description: "Show or stop force-showing a YouTube video when its channel is hidden. A shown video is back in the sources list and in knowledge for chat, search and reviews.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": ["type": "string", "description": "YouTube video source ID"],
                        "visible": ["type": "boolean", "description": "true to force visible, false to remove the override"],
                    ],
                    "required": ["source_id", "visible"],
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
                name: "set_group_hidden",
                description: "Hide or unhide a course, video playlist, or meeting group. Hiding is visual only: its sources leave the Studio sources list and stay in knowledge for chat, search and reviews.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "group_type": ["type": "string", "enum": ["course", "video_playlist", "meeting"], "description": "Kind of group."],
                        "group_key": ["type": "string", "description": "Course name, video-playlist id, or meeting group name."],
                        "hidden": ["type": "boolean", "description": "true to hide, false to unhide."],
                    ],
                    "required": ["group_type", "group_key", "hidden"],
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
            MCPToolDef(
                name: "generate_explainer",
                description: "Write a spoken explainer of a paper or article in ForeverLM and, by default, narrate it. Reads the source's full text and writes a plain-language script for the ear with the learner's Explainer Writing model — brief (about four minutes), standard (about seven) or extended (about twelve) — and saves it as a text source titled 'Explainer: <title>' that is listed under the original rather than on its own; the explainer is an ordinary source, so it can be opened, searched, reviewed and listened to on every device, and it is deleted with the source it explains. Then, unless generate_audio is false, starts text-to-speech audio for it exactly as generate_source_audio does: a free voice starts at once; when the voice costs money the audio part of the result is awaiting_confirmation with an estimate and nothing has been narrated yet — the script is already saved — so show the learner the estimate and, once they agree, call generate_source_audio with the explainer's source id and confirm_cost: true (or call this tool again with confirm_cost: true, which rewrites the script). With automatic audio switched on for explainers (get_automatic_audio_settings / set_automatic_audio_settings, kind explainer), that standing opt-in is the consent: the audio starts with the selected voice and no quote, and the audio result says cost_confirmed_by automatic_explainer_audio. A second call for the same source replaces its explainer. Bills the learner's OpenRouter key for the writing call.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "The paper or article to explain (from list_sources or a search).",
                        ],
                        "length": [
                            "type": "string",
                            "enum": ["brief", "standard", "extended"],
                            "description": "How long the spoken explainer runs: brief is about four minutes, standard (the default) about seven, extended about twelve.",
                        ],
                        "generate_audio": [
                            "type": "boolean",
                            "description": "Start text-to-speech audio for the explainer once it is written. Defaults to true.",
                        ],
                        "confirm_cost": [
                            "type": "boolean",
                            "description": "Pass true only after the learner has seen the audio estimate and explicitly agreed to the spend. Defaults to false, which quotes a paid voice and starts nothing — unless automatic audio is switched on for explainers (get_automatic_audio_settings), in which case that standing opt-in is the consent and the audio starts without a quote.",
                        ],
                    ],
                    "required": ["source_id"],
                ]
            ),
            Self.audioOverviewToolDef,
            Self.reportToolDef,
            MCPToolDef(
                name: "generate_explainer_video",
                description: "Make a short explainer video of one concept on this Mac: the Explainer Writing model storyboards it in eight-second scenes, the learner's video model (Settings › AI Models › Videos) films each scene with its narration, and the film is kept under Videos as a video source. Pass lecture_id to add the finished video to that course module as its video — the way a generated course gets a film for a module (lecture ids come from generate_course or get_course). A video costs dollars, so ForeverLM itself asks the learner the exact price in a dialog on the Mac before anything is filmed, every time; still tell the learner in chat which video you are starting and why before calling, and call it once per video they agreed to. The call returns as soon as the learner answers: started with a job_id while the film is made in the background (a few minutes; it appears in the module, or under Videos, when done), or declined, in which case nothing was made or billed. Mac only. cancel_ai_work with the returned work_id stops a film under way.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "concept": ["type": "string", "description": "The one idea the film explains, in plain words — \"why the electron transport chain pumps protons\", not a module title."],
                        "source_id": ["type": "string", "description": "Optional paper or article whose text grounds the storyboard."],
                        "length": [
                            "type": "string",
                            "enum": ExplainerVideoLength.allCases.map(\.rawValue),
                            "description": "brief (3 scenes, 24 s), standard (5 scenes, 40 s, the default) or extended (8 scenes, 64 s). The price scales with the scenes.",
                        ] as [String: Any],
                        "lecture_id": ["type": "string", "description": "Optional course module (lecture) to add the finished video to, as its video material."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks: the finished video joins that Notebook's sources. A video of a source or a module already shows wherever that source or course does; use it above all for a video of a concept alone. Checked before the price is asked."],
                    ],
                    "required": ["concept"],
                ]
            ),
            MCPToolDef(
                name: "generate_walkthrough",
                description: "Write a guided walkthrough of a paper, a book chapter or an article with ForeverLM's Walkthrough Writing model and open it beside the source in the Reader, as a deck of cards the learner also flips through on the phone. Two writing passes: the argument first — three to seven claims in teaching order — then chapters that teach those claims, one chapter a claim, each ending on its claim as a recap card. Ten to thirty steps, one point each, dealt one beat a card — a figure step is about one panel, which the Reader scrolls to and outlines while the cards read it (axes, traces, what the data do, what it means); an explain step is the guide talking, anchored to a passage the Reader marks only when the point is in the source's own words. A panel is shown when it carries a claim, not because it is printed. Questions along the way, about one step in three, in four kinds — recall, think_first (before the evidence), predict (the panel's data are hidden until the learner guesses) and find (the learner picks the panel that answers) — all open and answered in the learner's own words or on the figure, graded against the writer's reference answer, never multiple choice; Say more chips for context a newcomer may want; and small code-drawn animations for the steps whose mechanism a still figure cannot show. The first step situates the source in its field — what was known before it, the problem or debate it enters, why the question matters beyond its own system — as a journal's editorial summary would, and the last says what changes for the field if the authors are right. It explains the way a good textbook does, simply and step by step, for a newcomer to the field unless the learner's About you (account.about_you, also asked by Add Textbook) says otherwise: the terms and parts the argument needs are taught in plain words before the steps that use them, an abstract claim starts from a concrete case, each card says how it follows from the one before, and the questions ask about the argument rather than its vocabulary. The writer reads the source's text and, for a paper or a chapter split from a PDF, its figure index; an article or an EPUB chapter is shown as text, so its steps are anchored to passages alone, which the Reader scrolls to and flashes. Every figure label and quoted passage is checked against the source before saving, and a step whose anchor fails keeps its words and loses only the scroll target (the result's warnings say which). Every point card carries a picture: a figure step's panel, a figure the writer names for an explain step, or a picture drawn with the account's image model from the writer's brief (each kept with its prompt, as a drawn picture is); a step without one shows the picture before it in its chapter. The steps are saved and shown before anything is drawn, then the pictures and the animations are drawn one call each, so the walk is usable at once. A second call replaces the source's walkthrough. Bills the learner's OpenRouter key for the two writing calls, each picture and each animation; pass animations: false to write the steps alone. A paper can be walked through once its PDF has been read, a chapter or an article once its text has. A book is walked through one chapter at a time: call this per chapter (list_sources with the book's group lists them). To author the steps yourself instead — when you have already read the source and, for a paper, its figures with inspect_paper_figure — call save_walkthrough. The result's subject says what was walked (paper, chapter, article) and figure_anchors whether its steps may point at figures. A YouTube video is not walked through here: write its steps with save_walkthrough, each at its moment of the talk. While it runs, cancel_ai_work stops it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "The paper, book chapter or article (from list_sources or a search), or a foreverlm://source/<id> link.",
                        ],
                        "animations": [
                            "type": "boolean",
                            "description": "Draw the pictures and animations the writer briefed (at most ten pictures, four animations) through ForeverLM's separately billed media route. False saves the briefs undrawn so the connected assistant can make and save them with its own allowance. Defaults to false.",
                        ],
                    ],
                    "required": ["source_id"],
                ]
            ),
            MCPToolDef(
                name: "get_walkthrough",
                description: "Read a paper's, a book chapter's, an article's, a video's or a saved animation's walkthrough as the deck deals it: the title, who wrote it (the app or an assistant), its chapters (id, title, claim — the sentence the learner can say by the chapter's end — and step_ids), and every step with its kind (explain, figure, quiz), title, text, beats (one a card), more (Say more chips: label, text, from_paper), cites (the works the step cites, shown under its cards: title, authors, year, venue, kind, doi, url, and in_library with the library's source_id when it holds the work), anchor (figure_label, panel_label, passage, page_number, and at — a video step's moment, as m:ss), the figure's printed title (figure_title), the panel's own caption (panel_caption) and the sentence of the text that cites the panel (source_mention) for a figure step, its question (quiz: kind — recall, think_first, predict or find — question, answer, key_points, and target_panel for find; an open question graded against the reference answer) its picture (picture: figure_label and panel_label, or brief and image_id — the drawn picture's id on this Mac, readable with get_image) and whether it has an animation — inline, or by reference (animation: animation_id, title, step, conditions, url, the animation's page pinned to that step). status is ok, none (no walkthrough yet) or stale (the source's text, or the animation's address, changed since it was written, so it is not shown); subject says what the walk is of (paper, chapter, article, video, animation) and figure_anchors whether its steps may point at figures — false for a source shown as text, a video and an animation; moment_anchors is true for a video, whose steps point at moments of the talk. Pass source_id for a source or animation for a saved animation. Use it before rewriting one, and to walk a learner through the subject in conversation step by step.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "The paper, book chapter or article (from list_sources or a search), or a foreverlm://source/<id> link. Pass this or animation.",
                        ],
                        "animation": [
                            "type": "string",
                            "description": "Instead of source_id: a saved animation (its animation_id from list_animations). The walkthrough is then of the animation, played by the chat beside it, each step pinning the animation to one of its own steps.",
                        ],
                    ],
                ]
            ),
            MCPToolDef(
                name: "list_walkthroughs",
                description: "List every walkthrough in the library, newest first — a walkthrough rides its source, so each notebook's Studio lists those of the sources it holds: for each, its source (source_id, source_title, subject: paper, chapter, article or video), title, author (app or assistant), generated_at, step_count, card_count (one card a point, one a question — how many the deck deals), quiz_count, figure_step_count, animation_count, and status: ok while the walk matches the source's current text, stale once that text changed (generate_walkthrough or save_walkthrough replaces it). Pass notebook_id for only the walkthroughs of sources that Notebook holds. Read-only; get_walkthrough reads a walk's steps.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks: only the walkthroughs of sources it holds. A walkthrough rides its source, so it belongs to every Notebook holding that source (a team Notebook's copy of it included)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "save_walkthrough",
                description: "Save a walkthrough you wrote for a paper, a book chapter, an article or a YouTube video, to be played by the chat beside it in the Reader one step at a time — the in-Reader form of a figure companion site: the source stays on screen and your explanation moves over it, so never build a separate site to explain a source's figures when this will do. Read the source first (get_source_content) and, for a paper or a chapter split from a PDF, look at its figures (inspect_paper_figure, which also gives each figure's panels), then pass title and either chapters — one per claim of the source's argument, three to seven, each with a title, the claim as one sentence the learner could say back (plain words, about twenty at most, one point), and its steps, ending on a question — or a flat steps list. Teach the argument's claims, not a tour of the figures, and meet the figures in the order the source prints them (Figure 1 before Figure 2, panel a before panel b) unless the argument cannot be taught that way; a step that outlines a figure ahead of a lower-numbered one the learner has not seen yet says why, and when the earlier figures come, in its first beat, and warnings name such a jump. Walk each figure in one run of steps, with at most one deliberate return to a panel later on, and bring back a figure already walked as a step's picture rather than another step outlining it. A figure that carries no claim is left out, but a figure the walk shows has every panel inspect_paper_figure lists addressed before the walk leaves it: a step for each panel that carries a claim, a beat naming each other one, and warnings name a panel left unaddressed. Steps come in reading order, one point a step — the learner presses Next between them, so each says what to look at, what it shows and what it means, and stops. Explain it the way a good textbook does, simply and step by step, for a learner who is bright and willing but new to the field; when their About you is set (get_app_settings, account.about_you), pitch it to them instead. Teach the terms and parts the argument needs in beats of their own, in plain words, before the step that uses them, never in a more chip alone; bring in at most one or two new terms or names a card and leave out a name the walk never uses again; start an abstract claim from a concrete case the learner can picture; translate the source's language into plain words rather than rewording it; let each beat say how it follows from the one before (so, because, but); keep what is established apart from what is the author's proposal. Beyond the opening and closing field context, your own knowledge enters only as textbook background you are certain of — what a term means, a well-established mechanism, a concrete example — never as the source's finding. Write each step as beats: every beat is dealt as a card of its own — one short sentence — and a beat can name the panel it is about so the Reader's outline moves with it. A step may offer up to three more chips ({label, text, from_paper}) for context a newcomer may want and the argument can do without; from_paper is true only for the source's own words. A step whose point rests on a work the source names or cites — a paper, a book, an article, a talk — names it in cites (up to three), and its cards show it under the point as a card that opens the work where the library holds it and its page otherwise, with Add: copy the title and authors as the source or its reference list prints them, and give a doi or url only when the source prints it or you opened the page yourself, never one recalled; pass source_id when the library holds the work. Each step has kind (explain, figure or quiz), a short title, body (one to three plain paragraphs, about 60 to 150 words, blank-line separated, no Markdown headings; a figure step reads the panel before it interprets it — what that panel's own x and y axes plot (never a neighbouring panel's) and in what units, what each trace, colour or symbol is, then what the data do, then what it means — since the learner reads the body beside a figure they may find daunting). A figure step is about one panel: figure_label exactly as the source prints it (\"Figure 2\") with panel_label (\"a\"), which the Reader outlines on the page; two or three adjacent panels share a step only when they make one point together (panel_label the first, the body naming each), and no step tours a whole multi-panel figure. An explain step is the chat talking and takes an anchor only when its point is in the source's own words: passage (eight to forty words, copied exactly), which the Reader marks or flashes; a step that sets up or sums up carries no anchor and the Reader stays where it is; page_number (one-based) is a fallback. Open by situating the source in its field — what was known or believed before it, the open problem or debate it enters, why the question matters beyond the system it studies — as a journal's editorial summary would, marking what is the source's own account and what is yours and adding only what you can vouch for, and close with what changes for the field if the authors are right; a learner who reads the source alone gets only its specifics. An article and an EPUB chapter are shown as text and have no figures: anchor the steps of theirs that are about particular words with a passage; a figure_label on one is refused and named in warnings, and get_walkthrough's figure_anchors says beforehand which kind a source takes. A YouTube video is walked through by its talk, and this is the one way to write its walk: read its transcript (get_source_content, whose [m:ss] markers time each block) and look at its slides or any moment's frame (show_source_image), then give each step at, the moment of the talk it is about (\"12:34\" or whole seconds) — the Reader seeks the video there and holds it paused while the step's cards are read, so the learner sees what the talk showed then and presses play to hear it; a step that quotes the talk (passage, copied from one transcript block) and leaves at out is placed where the talk says the quote, and a step with neither leaves the video where it is. A video has no figures: its steps are explain and quiz steps, and a figure_label on one is refused. A quiz step carries quiz: {kind, question, answer, key_points, target_panel} — an open question the learner answers in their own words, graded by the chat's tutor against your reference answer and key points; never multiple choice (the old {options, correct_index, explanation} shape is still accepted for one release, saved as an open question with the correct option as the answer, and warned about). kind is recall (the default, about what the cards just showed), think_first (asked before the evidence), predict (the step points at a panel with figure_label and panel_label whose data stay hidden on the card and the page until the learner answers; answer says what the data show; one pointing at no figure is asked as think_first) or find (the step points at a figure with figure_label and no panel_label, and target_panel names the panel that answers, one of the figure's printed panels; the learner picks it on the figure). Write questions the way quantum.country's essays do: right after the point they test, usually two or three together, and at each chapter's end; one detail each, with one right answer; an answer that leads with a word, number, direction or name the learner can check at a glance; never yes or no, never a card's sentence with a word blanked out; the central ideas asked from more than one side; aimed at the argument — what a panel or passage showed and what it means for the claim, what causes what, why a control was needed — with some why and a little application; a term only when the walk keeps using it, asked for its meaning, never \"what does the author call X\"; no trivia; each question standalone, since it is read again away from the cards. Most are recall; use think_first, predict and find once or twice each where they earn it. Every point card shows a picture: a figure step's figure, or a step's picture — a figure of the source shown without outlining it, or an image drawn with generate_image (pass its image_id) — and a step without one shows the picture of the step before it in its chapter, so draw a new one only where the point moves on; an article or an EPUB chapter has no figures, so its pictures are drawn ones. A step's animation is dealt as a card of its own after the step's points, with no figure above it. A step may carry animation_html: one complete HTML document (inline SVG or Canvas, CSS and JavaScript; nothing loaded from the network, no storage, under 24,000 characters) that plays on a card of its own after the step's points and enlarged on request — at most six per walkthrough — or animation_brief, a description ForeverLM may draw later. Better than inline HTML for anything drawn more than once: a step may show a SAVED animation (from save_animation / list_animations) by reference — animation (its id or address), animation_step (one-based step of the animation's own player) and animation_conditions (condition id → value, as the animation's page reads them) — and the chat's card loads the animation's page pinned to that step, with no size limit; a pane showing the animation beside the chat is pointed at the step instead. A walkthrough can also be OF an animation: pass animation in place of source_id, and every step's animation defaults to it, so the chat beside the animation plays the walk and the page follows step by step. Such steps take no figure or passage anchors. A kit animation's build writes these steps as walkthrough.json (mitochondria animations/kit/build.py --walkthrough); pass them through. Every figure label and passage is checked against the source's figure index and text; a step whose anchor is not found keeps its words and loses the anchor, and warnings name each. At most 40 steps besides the questions, and at most 20 questions. Replaces the subject's existing walkthrough. Refused when the source's text has not been read yet. A book is walked through one chapter at a time: save one walkthrough per chapter.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "The paper, book chapter, article or YouTube video (from list_sources or a search), or a foreverlm://source/<id> link. Pass this or animation.",
                        ],
                        "animation": [
                            "type": "string",
                            "description": "Instead of source_id: a saved animation (its animation_id from list_animations). The walkthrough is then of the animation, played by the chat beside it, each step pinning the animation to one of its own steps.",
                        ],
                        "title": [
                            "type": "string",
                            "description": "A short title for the walk, without the word \"Walkthrough\".",
                        ],
                        "chapters": [
                            "type": "array",
                            "description": "Instead of steps: the walk in chapters, one per claim of the source's argument (three to seven, at most 10), each with a title, its claim as one sentence the learner could say back (its recap card), and its steps in reading order. The steps are one list underneath; at most 40 besides the questions, and 20 questions.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string", "description": "Two to five words naming the claim."],
                                    "claim": ["type": "string", "description": "One sentence the learner should be able to say by the chapter's end, specific enough to be wrong."],
                                    "steps": ["type": "array", "description": "The chapter's steps, shaped as the top-level steps are.", "items": ["type": "object"]],
                                ],
                                "required": ["title", "steps"],
                            ],
                        ],
                        "steps": [
                            "type": "array",
                            "description": "The steps in reading order, one point each, at most 40 besides the questions, and 20 questions. Pass this or chapters.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "kind": ["type": "string", "enum": ["explain", "figure", "quiz"], "description": "explain for a passage or idea, figure for a figure or panel the Reader outlines, quiz for an open question."],
                                    "title": ["type": "string", "description": "A short title for the step, at most eight words."],
                                    "body": ["type": "string", "description": "One to three plain paragraphs, about 60 to 150 words, separated by blank lines: what to look at, what it shows, what it means. No headings, lists or citations. May be left out when beats are given; it is then the beats run together."],
                                    "beats": [
                                        "type": "array",
                                        "description": "The step as the chat reveals it, one beat each time the learner presses Next: two to six single sentences of at most about 25 words — for a figure step, where to look, the axes, the legend, what the data do, and last the takeaway, which is what the step folds to once the walk moves on. Each beat is {text}, with panel_label (and figure_label for another figure) when it is about a different panel than the step's anchor; the Reader moves its outline there when the beat is shown. A bare string is taken as {text}. Without beats, the chat cuts body into sentences.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "text": ["type": "string"],
                                                "figure_label": ["type": "string", "description": "A figure the source prints, when the beat is about another figure than the step's."],
                                                "panel_label": ["type": "string", "description": "The panel the beat is about (\"b\")."],
                                            ],
                                            "required": ["text"],
                                        ],
                                    ],
                                    "more": [
                                        "type": "array",
                                        "description": "Up to three Say more chips on the step's cards: context offered, never pushed — a term, a method, a why a newcomer may want and an expert would skip.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "label": ["type": "string", "description": "The chip's words (\"What is ²³Na NMR?\")."],
                                                "text": ["type": "string", "description": "Two or three sentences shown when the chip is pressed."],
                                                "from_paper": ["type": "boolean", "description": "True only when the words are the source's own; anything else is labelled general knowledge."],
                                            ],
                                            "required": ["label", "text"],
                                        ],
                                    ],
                                    "cites": [
                                        "type": "array",
                                        "description": "Up to three works the step's point rests on that the source names or cites — a paper, a book, an article, a talk — each shown under the step's point cards as a card that opens it: the saved copy when the library holds it, else its page, with Add. Never the source being walked.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "title": ["type": "string", "description": "The work's title in full, as the source or its reference list prints it."],
                                                "authors": ["type": "string", "description": "Its authors as printed, separated by semicolons (\"Alexander Lerchner\", \"Hofmeyr J-HS; Cornish-Bowden A\")."],
                                                "year": ["type": "string", "description": "The year it appeared."],
                                                "venue": ["type": "string", "description": "The journal, publisher, preprint server or site."],
                                                "kind": ["type": "string", "enum": PaperWalkthroughCitation.Kind.allCases.map(\.rawValue), "description": "What the work is."],
                                                "doi": ["type": "string", "description": "Its DOI (10.x/y), only when the source prints it or you looked it up; never recalled."],
                                                "url": ["type": "string", "description": "An address of the work itself that the source prints or you opened; a foreverlm://source/<id> link names a library source."],
                                                "source_id": ["type": "string", "description": "The library source the work is, from list_sources or a search, when the library holds it."],
                                            ],
                                            "required": ["title"],
                                        ],
                                    ],
                                    "figure_label": ["type": "string", "description": "The figure's printed label, exactly as in the source (\"Figure 2\", \"Fig. 3\"). Only for a paper or a chapter split from a PDF; an article or an EPUB chapter has no figures to outline, and a label on one is refused."],
                                    "panel_label": ["type": "string", "description": "The one panel of the figure the step is about (\"a\"); every figure step sets it unless the figure's panels cannot be told apart."],
                                    "passage": ["type": "string", "description": "Eight to forty of the source's own words, copied exactly, for the Reader to find and mark — only when the step's point is in those words; a setup or summary step goes unanchored. The one anchor an article or an EPUB chapter takes."],
                                    "page_number": ["type": "integer", "description": "The one-based page the step is about, used when no figure or passage anchors it."],
                                    "at": ["type": "string", "description": "A YouTube video's step only: the moment of the talk the step is about — whole seconds (754) or a clock reading (12:34, 1:02:03). The Reader seeks the video there and holds it paused while the step's cards are read. Left out, a step whose passage quotes the talk is placed where the talk says it."],
                                    "picture": [
                                        "type": "object",
                                        "description": "The picture the step's point cards show when the step outlines no figure; a figure step's cards show its figure, and a question card only its own step's figure. Either a figure of the source shown without outlining it (figure_label, panel_label — a paper or a PDF chapter only), or a picture: image_id of one drawn with generate_image or kept with save_image, or brief, a picture for ForeverLM to draw later. A step without one shows the picture of the step before it in its chapter, so give one only where the point moves on.",
                                        "properties": [
                                            "figure_label": ["type": "string", "description": "The figure's printed label, as figure_label on a step."],
                                            "panel_label": ["type": "string", "description": "The panel of that figure (\"a\")."],
                                            "image_id": ["type": "string", "description": "A picture this Mac holds: its image_id from generate_image, save_image or list_images."],
                                            "brief": ["type": "string", "description": "What the picture must teach: the one idea it makes visible, what is drawn and how the parts relate, the few things labelled. No decoration and no invented data. Kept with the picture's image_id as what it was drawn from."],
                                        ],
                                    ],
                                    "animation_html": ["type": "string", "description": "A complete HTML document that animates the step's mechanism. Inline only; nothing from the network; under 24,000 characters."],
                                    "animation_brief": ["type": "string", "description": "A teaching plan for an animation of this step, for ForeverLM to draw later — not a scene. In order: the one sentence the learner should be able to say after watching; what in the figure or the text makes that hard to see; what is drawn and what moves, each motion standing for something; the conditions it compares and what changes between them; the measured values it should show."],
                                    "animation": ["type": "string", "description": "A saved animation this step shows (its animation_id or address). In a walkthrough of an animation it defaults to that animation."],
                                    "animation_step": ["type": "integer", "description": "The one-based step of the animation's own player the card pins to. Defaults to 1."],
                                    "animation_conditions": ["type": "object", "additionalProperties": ["type": "string"], "description": "Condition id → value for the animation's page (a choice's option value; \"1\" or \"0\" for a toggle), as the animation's walkthrough.json lists them."],
                                    "quiz": [
                                        "type": "object",
                                        "description": "An open question the learner answers in their own words, or on the figure for find; the chat's tutor grades a typed answer against answer and key_points and then gives answer. No options.",
                                        "properties": [
                                            "kind": ["type": "string", "enum": ["recall", "think_first", "predict", "find"], "description": "recall (default): about what the cards just showed. think_first: asked before the evidence. predict: the step's panel is hidden until the learner answers. find: the learner picks target_panel on the step's figure."],
                                            "question": ["type": "string"],
                                            "answer": ["type": "string", "description": "The reference answer, shown after grading: the short answer first (a word, a number with its unit, a direction, a name or one clause), then at most one sentence of why; for predict, what the data show; for find, what the target panel shows."],
                                            "key_points": ["type": "array", "items": ["type": "string"], "description": "The one to three things a complete answer mentions; for a single-fact question often just the one."],
                                            "target_panel": ["type": "string", "description": "find only: the letter of the panel that answers, one of the step's figure's printed panels."],
                                        ],
                                        "required": ["question", "answer"],
                                    ],
                                ],
                                "required": ["kind", "title"],
                            ],
                        ],
                    ],
                    "required": ["title"],
                ]
            ),
            MCPToolDef(
                name: "delete_walkthrough",
                description: "Remove a paper's, a book chapter's, an article's, a video's or a saved animation's walkthrough; the subject is untouched. Pass source_id or animation. Confirm with the learner first — a walkthrough an assistant authored cannot be brought back except by saving it again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "The paper, book chapter or article (from list_sources or a search), or a foreverlm://source/<id> link. Pass this or animation.",
                        ],
                        "animation": [
                            "type": "string",
                            "description": "Instead of source_id: a saved animation (its animation_id from list_animations). The walkthrough is then of the animation, played by the chat beside it, each step pinning the animation to one of its own steps.",
                        ],
                    ],
                ]
            ),
            MCPToolDef(
                name: "generate_course",
                description: "Plan and write a course on a topic from the learner's own library, optionally researching the live web and importing what it cites. Searches the library for the topic, plans a curriculum of modules over the sources found, writes a lesson and an exercise sheet per module as course sources, and saves it all as one course. Pass notebook_id to make that Notebook follow the course: it gains its sources and the modules it gains. The course itself lives in no Notebook. With schedule_start, a Goal in that Notebook, due the day after the last module, places one module every days_per_module days; with schedule_start and no notebook_id, an open-ended Notebook named after the course is created first, to follow the course and hold the Goal. Bills the learner's OpenRouter key on every run and takes minutes; tell the learner what it will do before calling it, and never call it twice for the same request. When the course was planned with the learner first, pass the sources they settled on as source_ids and the agreed outline as plan, and leave use_web off unless they want more research. Returns the course_id, lecture ids, and the lesson and exercise source ids; an explainer video for a module is made afterwards with generate_explainer_video and that module's lecture_id. While it runs, list_running_ai_work shows it and cancel_ai_work stops it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string", "description": "The subject of the course, e.g. \"mitochondrial transplantation\"."],
                        "learner_notes": ["type": "string", "description": "Optional: what the learner already knows or wants from the course."],
                        "use_web": ["type": "boolean", "description": "Research the topic on the live web and import cited pages as sources (default false)."],
                        "module_count": ["type": "integer", "description": "Optional preferred number of modules, \(CourseGenerationRequest.moduleCountRange.lowerBound)–\(CourseGenerationRequest.moduleCountRange.upperBound). Omit to size the course to the material."],
                        "schedule_start": ["type": "string", "description": "Optional YYYY-MM-DD. When set, a Goal in the course's Notebook is created and modules are placed on days from this date toward it; without notebook_id, a Notebook named after the course is created first. The answer carries notebook_id and goal_id."],
                        "days_per_module": ["type": "integer", "description": "Days between module study days when scheduling (default 2)."],
                        "quizzes": ["type": "boolean", "description": "Also write the course's quizzes once its lessons are written, as generate_course_quizzes does: a practice quiz after each module, checkpoints, and a course test (default false; one more model call per quiz)."],
                        "source_ids": ["type": "array", "items": ["type": "string"], "description": "Optional: library source ids the learner settled on for this course — found by search or imported while planning it. The planner places every one of them; the library search still adds what they miss. Import a web paper or video first (import_paper_from_url, add_source) and pass the id it returns."],
                        "plan": ["type": "string", "description": "Optional: the plan agreed with the learner, in plain words — the modules in order, what each covers and which chosen sources it reads, what to stress or leave out. The planner keeps it and fills in only what it leaves open."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks (of My Library) that follows the course. Checked before anything is paid for; an archived Notebook, or a team's, is refused."],
                    ],
                    "required": ["topic"],
                ]
            ),
            MCPToolDef(
                name: "generate_course_quizzes",
                description: "Write a course's quizzes ahead of time: a practice quiz after every lecture (about that lecture), a checkpoint quiz where a topic ends, about every few lectures (across them, some questions connecting lectures; the parts of a lecture series such as \"Ion Transport 1\" to \"4\" stay under one checkpoint), and a course test at the end. For each quiz the writer first lists every key point and fact worth remembering in the lecture videos, from the whole transcript, then asks at least one question about each, so a long lecture gets many questions; a point the list names that no question tests gets one more call for exactly those points. A lecture's readings are quizzed too: the textbook pages add_textbook_to_course planned for it, and any source filed under it with role reading. A practice quiz writes each reading's questions in a call of its own after the lecture's, and a checkpoint or the test reads the readings beside their lectures. Questions are open recall, never multiple choice, each tied to the lecture source or reading and the stretch it rests on (with its page, for a reading). Written from each lecture's stored transcript or text; lectures without one are listed so you can fetch_video_transcript them first. Every quiz is saved as it is written and shows in the course's Lectures list; by default only missing quizzes are written, so calling again resumes. Bills the learner's OpenRouter key: one model call per quiz, one more per reading of a practice quiz's lecture, and one more wherever the first call left a learning point without a question; takes a few minutes for a long course; tell the learner before calling. Image generation is off by default for an assistant's bulk run. With draw_pictures true, each newly written quiz also gets its picture and its writer may ask for up to \(CourseQuizPictures.maximumDrawingsPerQuiz) separately billed drawings for questions no slide or figure shows. That paid route is refused until the learner has seen the returned maximum image-request count, selected model and published maximum cost and explicitly agrees; then repeat it with confirm_drawings true and approved_spend_usd. Captured lecture slides and reading figures remain available without generated drawings. Returns the ladder with each quiz's quiz_id and status. While it runs, list_running_ai_work shows it and cancel_ai_work stops it; the quizzes already written stay.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from list_courses."],
                        "checkpoint_every": ["type": "integer", "description": "About how many lectures a checkpoint quiz covers, \(CourseQuizPlanning.checkpointEveryRange.lowerBound)–\(CourseQuizPlanning.checkpointEveryRange.upperBound) (default \(CourseQuizPlanning.defaultCheckpointEvery)). Checkpoints fall where a lecture series ends, so one can cover a few more or fewer. A course this short or shorter gets no checkpoints."],
                        "final_test": ["type": "boolean", "description": "Write the course test at the end (default true)."],
                        "rewrite": ["type": "boolean", "description": "Rewrite quizzes that already exist instead of keeping them (default false). A rewrite of the whole ladder also moves the checkpoints to where the ladder puts them now: a checkpoint written before its groups moved is removed once the new checkpoints cover its lectures. Without it, no checkpoint is written over lectures such an old one already covers."],
                        "quiz_ids": ["type": "array", "items": ["type": "string"], "description": "Optional: only these quizzes of the ladder, by the quiz_id get_course shows; with rewrite, rewrites just those."],
                        "draw_pictures": ["type": "boolean", "description": "Draw a picture for each newly written quiz that has none, and the separately billed pictures its writer asks for questions no slide or figure shows (default false for assistant bulk runs)."],
                        "confirm_drawings": ["type": "boolean", "description": "With draw_pictures true, pass true only after the learner has seen this tool's refusal with the maximum image-request count, selected model and published maximum cost and explicitly agreed. Pass that approval as approved_spend_usd too. Defaults false."],
                    ],
                    "required": ["course_id"],
                ]
            ),
            MCPToolDef(
                name: "add_course_quiz_pictures",
                description: "Give the questions of a course's quizzes already written the pictures that make their points clear, without rewriting a question: ids, scores and Memory items stay. The slides of every lecture video the quizzes cover are captured first when they never were (capture_slides, default true; it reads the video and takes a while for a long course). Then one model call per quiz, on the learner's Lecture Quiz Writing route, picks for each question the lecture slide or the reading figure (printed on the reading's pages) that helps and whether it is shown with the question or held for the answer. Drawing is off by default: draw false adds only those source pictures. With draw true, the picker may instead brief a new picture where no slide or figure shows the point, up to \(CourseQuizPictures.maximumDrawingsPerQuiz) a quiz, and ForeverLM draws the briefs on the learner's image model. That paid route is refused until the learner has seen the request count, selected model and published maximum cost and explicitly agrees; then repeat it with confirm_drawings true and approved_spend_usd. A question no picture helps gets none, and a question with a picture keeps it unless replace is true. choose false skips the picks and only draws pictures already briefed, with the same confirmation. For a quiz you wrote yourself you can instead look at frames and pages with show_source_image, or draw with generate_image or keep a picture made elsewhere with save_image, and pin it with set_course_quiz_picture. Returns, quiz by quiz, how many questions got a picture and how many were drawn. cancel_ai_work stops a run; the pictures already chosen and drawn stay.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from list_courses."],
                        "quiz_ids": ["type": "array", "items": ["type": "string"], "description": "Optional: only these quizzes, by the quiz_id get_course shows; default every quiz of the course."],
                        "capture_slides": ["type": "boolean", "description": "Capture the slides of lecture videos that have none first (default true). False uses only slides already captured."],
                        "replace": ["type": "boolean", "description": "Choose again for questions that already have a picture (default false)."],
                        "draw": ["type": "boolean", "description": "Brief and draw separately billed generated pictures for questions no slide or figure shows, and draw those already briefed (default false). False chooses slides and figures only."],
                        "confirm_drawings": ["type": "boolean", "description": "With draw true, pass true only after the learner has seen this tool's refusal with the maximum image-request count, selected model and published maximum cost and explicitly agreed. Pass that approval as approved_spend_usd too. Defaults false."],
                        "choose": ["type": "boolean", "description": "Choose slides, figures and drawings for questions without a picture (default true). False only draws the pictures already briefed."],
                    ],
                    "required": ["course_id"],
                ]
            ),
            MCPToolDef(
                name: "get_course_quiz",
                description: "Read one of a course's quizzes: its kind, the lectures it covers, where it sits in the course, the learner's latest score, and its questions with their ids, the lecture source each rests on, and the picture each is shown with, above the question or with its answer: a lecture's frame or a reading's page (show it with show_source_image as listed), an image in ForeverLM's store drawn for it or kept from another app (look at it with get_image), or a picture briefed and not drawn yet. Answers are left out unless include_answers is true, so you can quiz the learner one question at a time without showing them. Record each answer with record_course_quiz_result as it is graded.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "quiz_id": ["type": "string", "description": "Quiz ID from get_course or generate_course_quizzes."],
                        "include_answers": ["type": "boolean", "description": "Include each question's reference answer and key points, for grading (default false)."],
                    ],
                    "required": ["quiz_id"],
                ]
            ),
            MCPToolDef(
                name: "save_course_quiz",
                description: "Save a quiz you wrote into a course's structure, or replace one. kind practice is about one lecture and follows it; checkpoint covers several lectures and follows the last of them (a checkpoint closes a topic: it takes the parts of a lecture series such as \"Ion Transport 1\" to \"4\" whole, with any lone lecture beside them, about four lectures, never half a series); test covers the course (all lectures when lecture_ids is omitted) and ends it. Without quiz_id, a practice quiz, a checkpoint over the same lectures, or the course test replaces the one ForeverLM would write in that place. Work in two steps. First list the learning points, before writing any question: read each lecture video's whole transcript with get_source_content, first line to last, and each of the lecture's readings (get_course lists them; read a textbook reading's planned pages), and put every key point and fact worth remembering in learning_points, one short sentence each stating the point itself, in lecture order. A dense lecture teaches a point or more a minute, so a sixteen-minute lecture usually has fifteen or more; three is never all of them. Then write the questions from that list: every learning point gets at least one question, and each question names in points the learning points it tests. A quiz that leaves a point without a question is refused. Write it as a textbook's problem set, working up from recall through explain and apply to challenge problems that combine ideas, in that order. Questions are open: never multiple choice, each with one right answer. Tie each to the lecture source or reading it rests on with source_id so a miss can come back in Memory, give quote as the source's exact words (a quiz with a question on a source that has text and no quote the text contains is refused, naming each), and for a reading's question its page. Give a question a picture wherever seeing something makes its point clear — a slide's diagram, a structure, a graph, a pathway, an equation on the board, a figure of the reading — and the quiz shows it every time: look at the lecture video with show_source_image at the question's time, or at the reading's page, check it really shows the point (not just a title, the speaker, or a transition), crop to the part that matters, then pass the Markdown image line it returned as picture.image. Where nothing in the lecture or reading shows it, draw one with generate_image, or make it in another app and keep it with save_image, and pass its image_id; or pass brief and ForeverLM draws it later (add_course_quiz_pictures). show_with question puts it above the question, which may then point at it; show_with answer holds it until the learner has answered, for a picture that shows the answer. Leave pictures off questions a picture does not help. set_course_quiz_picture changes one question's picture without saving the quiz again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from list_courses."],
                        "kind": ["type": "string", "enum": ["practice", "checkpoint", "test"], "description": "practice, checkpoint or test."],
                        "quiz_id": ["type": "string", "description": "Optional: replace this quiz of the course."],
                        "title": ["type": "string", "description": "Optional title shown in the course: two to six words naming the topics the questions cover, e.g. \"Cristae and Supercomplexes\"."],
                        "symbol": ["type": "string", "description": "Optional SF Symbol name for the quiz's tile, suited to its topics, e.g. \"bolt.heart\" or \"atom\". A name this Mac does not have is ignored."],
                        "lecture_ids": ["type": "array", "items": ["type": "string"], "description": "The lectures the quiz is about (lecture ids from get_course): one for practice, several for a checkpoint."],
                        "after_lecture_id": ["type": "string", "description": "Optional: the lecture the quiz follows in the course; defaults to the last of lecture_ids."],
                        "learning_points": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Listed before the questions are written: every key point and fact worth remembering in the lectures' videos and their readings, one short sentence each stating the point itself (\"Cardiolipin has four acyl chains, not two\", not \"Cardiolipin structure\"), in lecture order, taken from the whole transcript. For a checkpoint or the test, each lecture's important points. Every point needs a question.",
                        ],
                        "questions": [
                            "type": "array",
                            "description": "The questions, in the order to ask them (at most \(CourseQuizPlanning.maximumQuestionsPerQuiz)): at least one for every learning point.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "question": ["type": "string"],
                                    "points": ["type": "array", "items": ["type": "integer"], "description": "The learning points the question tests, by their number in learning_points, counting from 1."],
                                    "level": ["type": "string", "enum": ["recall", "explain", "apply", "challenge"], "description": "Optional: how far up the problem set the question sits — recall (what was said), explain (why or how), apply (an idea used on a new case), challenge (several ideas, more than one step)."],
                                    "answer": ["type": "string", "description": "The reference answer: the short answer first, then at most one sentence why; for an apply or challenge problem, the result and then the reasoning in at most three sentences."],
                                    "key_points": ["type": "array", "items": ["type": "string"], "description": "One to three things a complete answer mentions."],
                                    "source_id": ["type": "string", "description": "The lecture source or reading the question rests on."],
                                    "start_seconds": ["type": "number", "description": "Optional: where in the video to rewatch, for a source whose text carries no times. A question on a timed transcript is timed from its quote, where the lecture says it, and this is ignored."],
                                    "page": ["type": "integer", "minimum": 1, "description": "Optional, for a question about a reading: the page of the source it rests on, counted from 1 within the source as get_source_content's [page N] lines count it, for Reread."],
                                    "quote": ["type": "string", "description": "The Memory anchor: eight to twenty-five words in a row copied from the source's text as get_source_content returns it. Required with a source_id whose source has text; a question without one, or quoting words the text does not contain, is refused, since a miss on it could never come back in review."],
                                    "picture": Self.courseQuizPictureSchema,
                                ] as [String: Any],
                                "required": ["question", "answer", "points"],
                            ] as [String: Any],
                        ],
                    ],
                    "required": ["course_id", "kind", "learning_points", "questions"],
                ]
            ),
            MCPToolDef(
                name: "delete_course_quiz",
                description: "Remove one quiz from a course by its quiz_id. The learner's latest score for it is kept. generate_course_quizzes writes a ForeverLM quiz again when asked.",
                inputSchema: [
                    "type": "object",
                    "properties": ["quiz_id": ["type": "string", "description": "Quiz ID from get_course."]],
                    "required": ["quiz_id"],
                ]
            ),
            MCPToolDef(
                name: "rename_course_quiz",
                description: "Rename one of a course's quizzes, and optionally change its symbol, without touching its questions, picture or scores. The title names the topics its questions cover, two to six words in title case, without the word \"Quiz\" (for example \"Cristae and Supercomplexes\"); the course's list shows it in place of the plain \"Quiz\".",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "quiz_id": ["type": "string", "description": "Quiz ID from get_course."],
                        "title": ["type": "string", "description": "The quiz's new title."],
                        "symbol": ["type": "string", "description": "Optional SF Symbol name for the quiz's tile."],
                    ],
                    "required": ["quiz_id", "title"],
                ]
            ),
            MCPToolDef(
                name: "set_course_quiz_picture",
                description: "Pin a picture to one question of a course quiz, replace its picture, or take it away (remove true), without touching the question or the rest of the quiz: ids, scores and Memory items stay. The picture is one of: a lecture's frame or a reading's page or figure, as the Markdown line show_source_image returned (picture.image), or at a time (picture.at) or page (picture.page) of the question's own source with an optional crop; an image in ForeverLM's store by picture.image_id — drawn with generate_image, or made in ChatGPT, Claude or another app and kept with save_image; or a brief (picture.brief) for ForeverLM to draw, which add_course_quiz_pictures draws. show_with question shows it above the question, which must then not give the answer away; show_with answer holds it for the grade. The question's id is the one get_course_quiz lists in brackets. Returns the picture as the quiz now shows it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "quiz_id": ["type": "string", "description": "Quiz ID from get_course."],
                        "question_id": ["type": "string", "description": "The question's id, as get_course_quiz lists it in brackets before the question."],
                        "picture": Self.courseQuizPictureSchema,
                        "remove": ["type": "boolean", "description": "Take the question's picture away instead (default false)."],
                    ],
                    "required": ["quiz_id", "question_id"],
                ]
            ),
            MCPToolDef(
                name: "record_course_quiz_result",
                description: "Record answers to a course quiz taken in this chat as the quiz goes: call it after each graded answer, or a few at a time, with one result per question answered since the last call, graded by you against the reference answer (get_course_quiz with include_answers). Each call adds to the quiz's sitting under way, the same sitting the app's Continue Quiz picks up whether it was begun here, in another chat or in the app, or starts one when none is; the reply gives its sitting_id and the next question to ask. The sitting keeps each question, answer and your feedback as a ForeverLM chat, the quiz's row in the course shows it under way, and every miss becomes a Memory item that comes back in spaced review as soon as it is recorded. It completes once every question has an outcome, or when you pass finish true because the learner stops, and questions without an outcome then count as skipped; the quiz's row then shows the score, exactly as a sitting in the app does. Recording a question again corrects its grade.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "quiz_id": ["type": "string", "description": "Quiz ID from get_course."],
                        "results": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "question_id": ["type": "string", "description": "The question's id, as get_course_quiz lists it in brackets before the question."],
                                    "outcome": ["type": "string", "enum": ["correct", "partial", "incorrect", "remembered", "forgot", "skipped"], "description": "correct, partial or incorrect for a graded answer; remembered or forgot when the learner graded themselves; skipped."],
                                    "answer": ["type": "string", "description": "The learner's answer, in their words."],
                                    "feedback": ["type": "string", "description": "What you told them."],
                                ] as [String: Any],
                                "required": ["question_id", "outcome"],
                            ] as [String: Any],
                        ],
                        "sitting_id": ["type": "string", "description": "Optional: the sitting to add to, as an earlier call's reply or get_course_quiz names it. Leave it out to go on with the quiz's sitting under way, or to start one when none is; pass it to correct an answer in a sitting already completed."],
                        "new_sitting": ["type": "boolean", "description": "Optional: true starts a new sitting from question 1 even though one is under way, when the learner wants to start over (default false)."],
                        "finish": ["type": "boolean", "description": "Optional: true ends the sitting now, when the learner stops before the last question; the questions without an outcome count as skipped and the score is recorded (default false: the sitting completes once every question has an outcome)."],
                    ],
                    "required": ["quiz_id", "results"],
                ]
            ),
            MCPToolDef(
                name: "save_course_textbook_readings",
                description: "Save the targeted textbook readings you selected yourself, without asking a ForeverLM model to plan them. First inspect the course with get_course, find the book's chapter sources with list_sources or search_sources_keyword, and read the relevant chapters with get_source_content. Pass the complete reading set for this book: each lecture, chapter source, optional one-based page range within that chapter, a learner-facing title, and an optional reason. Omitting both page fields assigns the whole chapter. The call validates that every lecture belongs to the course, every chapter belongs to the book, and every page fits the chapter, then replaces only this book's prior readings; videos, quizzes, ordinary readings, and other books stay. It makes no model or media call and costs nothing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from get_course."],
                        "book": ["type": "string", "description": "The book: its title as the library shows it, its book id, or the source_id of any chapter."],
                        "readings": [
                            "type": "array",
                            "minItems": 1,
                            "description": "The complete replacement reading set from this book, at most three readings per lecture.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "lecture_id": ["type": "string", "description": "Exact lecture_id from get_course."],
                                    "chapter_source_id": ["type": "string", "description": "Exact source_id of a chapter belonging to the named book."],
                                    "first_page": ["type": "integer", "minimum": 1, "description": "Optional first page within the chapter, one-based and inclusive. Give together with last_page; omit both for the whole chapter."],
                                    "last_page": ["type": "integer", "minimum": 1, "description": "Optional last page within the chapter, one-based and inclusive. Give together with first_page; omit both for the whole chapter."],
                                    "title": ["type": "string", "description": "The section or page-range title shown in the course. Required for a page range; optional for a whole chapter, whose chapter title is used by default."],
                                    "reason": ["type": "string", "description": "Optional concise reason this reading belongs after this lecture, at most \(TextbookReadingPlanning.maximumReasonCharacters) characters."],
                                ] as [String: Any],
                                "required": ["lecture_id", "chapter_source_id"],
                            ] as [String: Any],
                        ],
                    ],
                    "required": ["course_id", "book", "readings"],
                ]
            ),
            MCPToolDef(
                name: "add_textbook_to_course",
                description: "Integrate a textbook from the learner's library into a course as targeted reading: for each lecture, the sections of the book this learner should read with it (a run of pages within a chapter, or a whole chapter when it has no sections), and why, placed after the lecture in the course. The Textbook Readings model chooses them from the course title, each lecture's transcript, and the sections the book's own chapter files carry. When the learner has supplied About you, a course focus, or linked Notebooks, those further tailor the plan; when they have not, the course materials are sufficient and no personal background is inferred. Sections covering what the learner says they already know are left out, and a lecture the book adds nothing to gets no reading. Calling again with the same book replaces that book's readings; videos, quizzes and other books' readings stay. Bills the learner's OpenRouter key for one planning call and takes about a minute. Returns each reading with its lecture, chapter source_id, pages, item_id and reason.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from list_courses."],
                        "book": ["type": "string", "description": "The book: its title as the library shows it, its book id, or the source_id of any of its chapters."],
                        "learner_background": ["type": "string", "description": "Optional: where the learner is coming from, in their own words: their background, what they know well, what is new to them. Saved as their About you, which every course reads. At most \(LearnerProfile.maximumAboutYouLength) characters."],
                        "course_focus": ["type": "string", "description": "Optional: what the learner needs from this course, in their own words. Saved for this course. At most \(LearnerProfile.maximumFocusLength) characters."],
                    ],
                    "required": ["course_id", "book"],
                ]
            ),
            MCPToolDef(
                name: "update_course",
                description: "Update an existing course's display metadata, or make a Notebook follow it (or stop following it). A course lives in no Notebook: it stands beside Notebooks, and a Notebook may follow it so its sources, and every source the course gains, join that Notebook. Requires the exact stable course_id from list_courses. Omit fields to keep them unchanged; pass an empty course_code, institution, instructors, or playlist_url to clear that field.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Exact stable course ID from list_courses."],
                        "title": ["type": "string", "description": "New non-empty course display title (optional)."],
                        "course_code": ["type": "string", "description": "Course code, e.g. CS336 (optional; empty clears)."],
                        "institution": ["type": "string", "description": "Institution, e.g. Stanford (optional; empty clears)."],
                        "instructors": ["type": "string", "description": "Instructor names (optional; empty clears)."],
                        "playlist_url": ["type": "string", "description": "Official course playlist URL (optional; empty clears)."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks that follows the course from now on: it gains the course's sources and every source the course gains later. Other Notebooks keep following it; the course itself lives in no Notebook."],
                        "unlink_notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks that stops following the course. It keeps the sources it holds; later lectures no longer join it."],
                    ],
                    "required": ["course_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_course",
                description: "Delete a course collection while preserving its sources as ungrouped library items. This removes the course's metadata, lectures, and material relationships. Requires the exact stable course_id from list_courses and cannot be undone — confirm with the user first.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Exact stable course ID from list_courses."],
                    ],
                    "required": ["course_id"],
                ]
            ),
            MCPToolDef(
                name: "create_course_lecture",
                description: "Create a numbered lecture inside an existing course. Call list_courses first and pass its stable course_id. A unique exact display title is accepted for backward compatibility; ambiguous titles fail instead of creating or choosing a duplicate. Exactly one of course_id or course_name is required. Number auto-assigns to the next available unless given.",
                // The either/or lives in the descriptions: the Claude API rejects
                // anyOf/oneOf/allOf at the top level of a tool's input schema.
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "course_id": ["type": "string", "description": "Stable course ID from list_courses (preferred). Required unless course_name is given."],
                        "course_name": ["type": "string", "description": "Backward-compatible unique exact course display title. Used only when course_id is omitted."],
                        "title": ["type": "string", "description": "Lecture title (optional)"],
                        "number": ["type": "integer", "description": "Lecture number (optional; auto-assigned if omitted)"],
                    ],
                ]
            ),
            MCPToolDef(
                name: "rename_course_lecture",
                description: "Rename a course lecture by ID.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "lecture_id": ["type": "string", "description": "Lecture ID"],
                        "title": ["type": "string", "description": "New lecture title"],
                    ],
                    "required": ["lecture_id", "title"],
                ]
            ),
            MCPToolDef(
                name: "add_source_to_lecture",
                description: "Attach any source to a course lecture as a material. For paper sources, prefer add_paper_to_lecture so the source type is validated and duplicate associations are avoided.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "lecture_id": ["type": "string", "description": "Lecture ID"],
                        "source_id": ["type": "string", "description": "Source ID to attach"],
                        "role": ["type": "string", "enum": ["video", "notes", "slides", "exercise", "reading", "article", "podcast", "code", "reference", "other"], "description": "Material role (optional, default other)"],
                    ],
                    "required": ["lecture_id", "source_id"],
                ]
            ),
            MCPToolDef(
                name: "add_paper_to_lecture",
                description: "Associate an existing paper source with a course lecture, as assigned reading or as a paper the lecture only cites. Assigned reading is a row of the course's path and is quizzed with its lecture; on a lecture with a video, a paper that is only cited has no row and opens from the video's Papers menu. Validates that source_id is an active paper and returns the durable lecture-item ID. Calling it for a paper already attached changes nothing unless assigned_reading is given, which sets how the paper stands.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "lecture_id": ["type": "string", "description": "Lecture ID returned by get_course."],
                        "source_id": ["type": "string", "description": "Existing paper source ID."],
                        "assigned_reading": ["type": "boolean", "description": "true when reading the paper is actually necessary for the course (the syllabus or lecturer assigns it, the lecture is built on it, or the learner asks); false when the lecture only cites it, as on a slide. Omitted, a new association is assigned reading and an existing one keeps its standing."],
                    ],
                    "required": ["lecture_id", "source_id"],
                ]
            ),
            MCPToolDef(
                name: "find_lecture_papers",
                description: "Find the papers cited by every active video, notes file, syllabus, slide deck, and other readable material attached to one course lecture, and record each as a candidate without importing or attaching anything. The tool scans complete video decks, lecture transcripts, and all bounded chunks of stored text; verifies model-returned URLs and DOIs against the literal material; resolves citations against the scholarly catalogs; and returns one candidate per paper with its cited_paper_id, status (pending: can be imported; imported: already in the library; unresolved: no record matched; dismissed), the materials it was found in, and whether it is already attached to the lecture. Show the learner the candidates and pass the ones they choose to ingest_lecture_papers. Existing video scan decisions are reused by default; pass force true to re-extract and rescan each video's slides and transcript while merging without overwriting prior decisions.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "lecture_id": ["type": "string", "description": "Lecture ID returned by get_course."],
                        "force": ["type": "boolean", "description": "Re-extract and rescan lecture videos, merging new citations while preserving existing imported/dismissed decisions. Text materials are read on every invocation. Defaults to false."],
                    ],
                    "required": ["lecture_id"],
                ]
            ),
            MCPToolDef(
                name: "ingest_lecture_papers",
                description: "Import the lecture paper candidates the learner chose and attach them to the lecture. Pass the cited_paper_ids returned by find_lecture_papers; this tool discovers nothing itself. A pending candidate is downloaded through the normal deduplicating Paper Metadata pipeline and attached; an imported one already in the library is attached; dismissed and unresolved ones are skipped with the reason. A paper is attached as one the lecture only cites: it opens from the lecture video's Papers menu, has no row in the course's path, and is not quizzed. Only the ids also in assigned_reading_ids become assigned reading, a row of the course quizzed with its lecture. Every id is checked against the lecture's materials before any download starts. Returns what was attached, skipped, or failed, and the lecture's final associated papers.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "lecture_id": ["type": "string", "description": "Lecture ID returned by get_course."],
                        "cited_paper_ids": ["type": "array", "items": ["type": "string"], "description": "cited_paper_id of each candidate from find_lecture_papers the learner chose to ingest."],
                        "assigned_reading_ids": ["type": "array", "items": ["type": "string"], "description": "Optional subset of cited_paper_ids to attach as assigned reading: only papers whose reading is actually necessary for the course (the syllabus or lecturer assigns it, the lecture is built on it, or the learner asks), never one merely cited on a slide. An already attached paper listed here becomes assigned reading."],
                    ],
                    "required": ["lecture_id", "cited_paper_ids"],
                ]
            ),
            MCPToolDef(
                name: "remove_course_lecture_item",
                description: "Remove a material from a course lecture by its lecture-item ID.",
                inputSchema: [
                    "type": "object",
                    "properties": ["item_id": ["type": "string", "description": "Course lecture item ID"]],
                    "required": ["item_id"],
                ]
            ),
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
        ] + MCPDataStore.imageToolDefs + Self.settingsParityToolDefs + Self.runningWorkToolDefs + Self.mnemonicReadingToolDefs + Self.knowledgeMapToolDefs + Self.canvasCatalogToolDefs + Self.spaceListToolDefs + Self.canvasAskToolDefs
            + Self.sourceLevelsToolDefs
            + Self.canvasMemoryToolDefs // Memory on the Canvas (WP-B2)
            + Self.atlasToolDefs
            + Self.notesGraphToolDefs // Notes as a graph (MCPTools+NotesGraph.swift)
            + Self.paperReferenceToolDefs // A paper's reference list (MCPTools+PaperReferences.swift)
        return definitions.map(Self.addSpendApprovalArgument)
    }

    /// Every assistant-started paid operation has a $3 default ceiling. A
    /// larger ceiling is deliberately part of the tool call, rather than a
    /// preference an assistant can silently inherit from an earlier run.
    private static func addSpendApprovalArgument(to tool: MCPToolDef) -> MCPToolDef {
        guard paidWorkToolNames.contains(tool.name),
              var properties = tool.inputSchema["properties"] as? [String: Any] else { return tool }
        properties["approved_spend_usd"] = [
            "type": "number",
            "minimum": 0.01,
            "description": "Maximum USD the learner has approved for this one operation. Omit for the $3 default ceiling. Pass more than 3 only after showing the learner the estimate or published maximum and receiving explicit approval. The operation stops after the request that reaches the ceiling and starts no further paid request; completed work is kept.",
        ]
        var schema = tool.inputSchema
        schema["properties"] = properties
        return MCPToolDef(
            name: tool.name,
            description: tool.description + " Paid assistant work has a $3 per-operation ceiling by default. To continue beyond it, show the learner the estimate, obtain explicit approval, and pass that total as approved_spend_usd.",
            inputSchema: schema
        )
    }

    // MARK: - Tool Dispatch

    static func title(for toolName: String) -> String {
        let words = toolName.split(separator: "_").map { word -> String in
            let text = String(word)
            guard let first = text.first else { return text }
            return first.uppercased() + String(text.dropFirst())
        }
        return words
            .joined(separator: " ")
            .replacingOccurrences(of: "Mcp", with: "MCP")
            .replacingOccurrences(of: "Ai", with: "AI")
            .replacingOccurrences(of: "Pdf", with: "PDF")
            .replacingOccurrences(of: "Url", with: "URL")
            .replacingOccurrences(of: "Youtube", with: "YouTube")
    }

    /// Whether a tool changes nothing. It decides more than consent wording: a
    /// read shares the store gate and triggers no reload here, and the gateway
    /// reads it from the published catalogue (`readOnlyHint`) to decide which
    /// calls the hosted mirror may answer once the relay may have handed the
    /// call to this Mac, since a read is safe to run twice and a write is not.
    static func isReadOnlyTool(_ toolName: String) -> Bool {
        readOnlyToolNames.contains(toolName) || settingsParityReadOnlyToolNames.contains(toolName)
    }

    /// ChatGPT Apps SDK treats missing tool impact annotations as a descriptor
    /// validation error. These hints only affect client-side consent wording; the
    /// server still enforces OAuth and tool-specific validation.
    static func annotations(for toolName: String) -> [String: Any] {
        let readOnly = isReadOnlyTool(toolName)
        return [
            "readOnlyHint": readOnly,
            "destructiveHint": !readOnly && destructiveToolNames.contains(toolName),
            "openWorldHint": !readOnly && openWorldToolNames.contains(toolName),
        ]
    }

    /// The whole tool surface an ingest-scoped (`mcp:ingest`) client may use.
    /// Everything else — reads, deletes, notebook/schedule state, outbound
    /// writes — is refused at dispatch and hidden from that client's
    /// tools/list.
    static let ingestAllowedTools: Set<String> = [
        "add_source", "add_sources", "update_source_content", "get_connector_inbox",
        "import_connector_paper", "get_mcp_status", "report_connector_status",
    ]

    /// Maximum items per `add_sources` call. The hosted relay forwards a
    /// request as a single WebSocket frame, so huge batches fail in transport
    /// anyway; this cap turns that into a clear, actionable error instead.
    static let maxBatchSourceItems = 50

    static func isToolAllowed(_ name: String, scope: MCPAuthScope) -> Bool {
        switch scope {
        case .full: return true
        case .ingest: return ingestAllowedTools.contains(name)
        }
    }

    /// An ingest plugin files into the library; which Notebook a source
    /// belongs in is the learner's (and their assistant's) call, so an
    /// add_source or add_sources from that scope naming a notebook_id is
    /// refused before anything is added.
    static func ingestNotebookRefusal(_ arguments: [String: Any], access: MCPAccessContext) -> String? {
        guard access.scope == .ingest,
              MCPDataStore.nilIfBlank(arguments["notebook_id"] as? String ?? "") != nil else { return nil }
        return "Error: notebook_id is not available to an ingest-only plugin. Nothing was added; add the source without notebook_id."
    }

    static func scopeRefusalMessage(toolName: String) -> String {
        "This connection is authorized with the ingest-only scope (mcp:ingest) and cannot call \(toolName). "
            + "Ingest connections may use: \(ingestAllowedTools.sorted().joined(separator: ", ")). "
            + "Reconnect with the full scope (mcp:tools) to use the rest of ForeverLM."
    }

    /// A tool call's outcome with an explicit error flag, so in-app callers never
    /// have to infer failure from message prefixes.
    struct ToolCallOutcome {
        let text: String
        let isError: Bool
        /// Pictures the tool hands back beside its text — a paper figure, a
        /// slide — which the protocol layer emits as MCP `image` content parts
        /// after the text. Empty for every tool but the picture tools.
        var images: [MCPToolImage] = []
    }

    /// The added-to-the-library window a source search asked for, under either
    /// spelling.
    ///
    /// The filters shipped as `date_from`/`date_to`, and that name is most of
    /// why they were misused: on a library search "date" reads as the source's
    /// own date, so a model asked about a 2021 book put 2021 here and lost a
    /// round to the refusal. The advertised names now carry the axis. The old
    /// ones still work — remote MCP clients hold cached schemas, and a caller
    /// that learned them should not break for having been early.
    static func searchAddedWindow(_ arguments: [String: Any]) -> (from: String?, to: String?) {
        (
            from: arguments["added_from"] as? String ?? arguments["date_from"] as? String,
            to: arguments["added_to"] as? String ?? arguments["date_to"] as? String
        )
    }

    func callTool(name rawName: String, arguments: [String: Any], access: MCPAccessContext) async -> String {
        await callToolDetailed(name: rawName, arguments: arguments, access: access).text
    }

    /// - Parameter hostSessionID: the review session the caller is already inside.
    ///   In-app Chat is itself a recorded review session, so the session-creating
    ///   tools must bind to it instead of inserting a second, exchange-less session
    ///   row that shows up in the session browser as an unresumable phantom chat.
    ///   Remote MCP clients have no session of their own and pass nil.
    /// - Parameter access: what the caller's credential authorizes. Defaults to
    ///   `.internalFullAccess`, which is correct only for in-app callers — the
    ///   app process is the owner. Remote MCP entry points must always pass the
    ///   context derived from the request's bearer token.
    func callToolDetailed(
        name rawName: String,
        arguments: [String: Any],
        hostSessionID: String? = nil,
        access: MCPAccessContext = .internalFullAccess
    ) async -> ToolCallOutcome {
        let name = rawName
        // Defense in depth: the MCP protocol handler already refuses
        // out-of-scope calls with a JSON-RPC error before reaching here.
        guard Self.isToolAllowed(name, scope: access.scope) else {
            return ToolCallOutcome(text: "Error: \(Self.scopeRefusalMessage(toolName: rawName))", isError: true)
        }
        // Listing and stopping running work is not work to list or stop.
        if Self.runningWorkToolNames.contains(name) {
            return await performToolCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access)
        }
        let spendLimitUSD: Double?
        if Self.paidWorkToolNames.contains(name) {
            if let raw = arguments["approved_spend_usd"] {
                guard !(raw is Bool),
                      let number = raw as? NSNumber,
                      number.doubleValue.isFinite,
                      number.doubleValue > 0 else {
                    return ToolCallOutcome(text: "Error: approved_spend_usd must be a positive finite number.", isError: true)
                }
                spendLimitUSD = number.doubleValue
            } else {
                spendLimitUSD = MCPRunningWork.defaultSpendLimitUSD
            }
        } else {
            spendLimitUSD = nil
        }
        // The same call made again while the first still runs, most often an
        // assistant retrying after its request timed out, waits for that one's
        // answer rather than doing the work twice (MCPRepeatedCalls).
        guard let key = Self.repeatedCallKey(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) else {
            return await runListedCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access, spendLimitUSD: spendLimitUSD)
        }
        let outcome = await repeatedCalls.value(for: key) {
            await self.runListedCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access, spendLimitUSD: spendLimitUSD)
        }
        return outcome ?? ToolCallOutcome(
            text: "\(Self.stoppedResultPrefix) waiting for \(name). The same call goes on for another caller that made it.",
            isError: true
        )
    }

    /// One call, listed in `MCPRunningWork` while it runs.
    private func runListedCall(
        name: String,
        arguments: [String: Any],
        hostSessionID: String?,
        access: MCPAccessContext,
        spendLimitUSD: Double?
    ) async -> ToolCallOutcome {
        // Every other call runs as a task `cancel_ai_work` can stop, however
        // long it takes and whether or not its caller is still waiting.
        let run = await MCPRunningWork.shared.run(
            toolCall: name,
            about: MCPRunningWork.about(arguments),
            spendLimitUSD: spendLimitUSD
        ) {
            await self.performToolCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access)
        }
        guard let stopper = run.stoppedBy, !run.value.text.hasPrefix(Self.stoppedResultPrefix) else { return run.value }
        // What a stopped call saved before it stopped is real, so the open
        // windows reload whatever the call itself answered.
        if Self.isMutatingTool(name) {
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
        let next = stopper == .spendLimit
            ? " Ask the learner before continuing. After explicit approval, repeat the operation with the approved total in approved_spend_usd."
            : ""
        return ToolCallOutcome(
            text: "\(Self.stoppedResultPrefix) \(stopper.answerPhrase) before \(name) finished. What it had already saved is kept.\(next)\n\n\(run.value.text)",
            isError: true,
            images: run.value.images
        )
    }

    /// One tool call: the store gate, the dispatch, and the refresh signal.
    private func performToolCall(
        name: String,
        arguments: [String: Any],
        hostSessionID: String?,
        access: MCPAccessContext
    ) async -> ToolCallOutcome {
        // One cached KnowledgeStore connection is shared by every tool. SQLite's
        // FULLMUTEX serializes individual calls, not a complete transaction, so a
        // nominally read-only tool can otherwise slip between statements and see
        // another task's uncommitted state. Hold the gate for the entire allowed
        // tool execution: a tool that writes holds it alone, a tool that only
        // reads shares it with every other reader. Non-store work inside a tool
        // deliberately shares that correctness boundary. Two kinds of tool are
        // left out: those that never touch the cached connection, and the long
        // paid ones that take the gate themselves around each stretch that
        // does, so their model calls hold nothing.
        let holdsStoreGate = !Self.storeGateExemptToolNames.contains(name)
            && !Self.selfGatedToolNames.contains(name)
            && !Self.settingsParityToolNames.contains(name)
        let gateMode = Self.storeGateMode(for: name)
        if holdsStoreGate { await store.acquireToolOperation(gateMode) }
        // Stopped while it waited for the gate, most often behind the very
        // writer the learner stopped with it: nothing has run, so nothing runs.
        if Task.isCancelled {
            if holdsStoreGate { await store.releaseToolOperation() }
            return ToolCallOutcome(text: "\(Self.stoppedResultPrefix) before \(name) started. Nothing was done.", isError: true)
        }
        let normalizedArguments = Self.normalizedArguments(
            toolName: name,
            arguments: Self.argumentsShaped(
                toSchema: tools.first(where: { $0.name == name })?.inputSchema ?? [:],
                arguments: arguments
            )
        )
        // A call an AI app made that sets ForeverLM's models to work draws its
        // popup in the Studio window while it runs (MCPToolActivity.swift).
        let activity = await store.beginToolActivity(name: name, arguments: normalizedArguments, access: access)
        let hold = holdsStoreGate ? MCPStoreGateHold(gateMode) : nil
        let chatModel = access.clientID == MCPAccessContext.internalFullAccess.clientID && ChatRequestedModel.toolNames.contains(name)
            ? ChatRequestedModel.config(forSession: hostSessionID)
            : nil
        let outcome: ToolCallOutcome = await ChatRequestedModel.$current.withValue(chatModel) {
          await MCPStoreGateHold.$current.withValue(hold) {
            await MCPToolActivityReporter.$current.withValue(activity) {
                if let media = await executeMediaTool(name: name, arguments: normalizedArguments) {
                    // The picture tools answer with text and images; every other tool
                    // is a string, and the string switch below stays as it is.
                    return ToolCallOutcome(text: media.text, isError: media.isError, images: media.images)
                }
                let result = await executeTool(
                    name: name,
                    arguments: normalizedArguments,
                    hostSessionID: hostSessionID,
                    access: access
                )
                return ToolCallOutcome(text: result, isError: Self.isFailureResult(result))
            }
          }
        }
        hold?.end()
        await activity?.end(outcome)
        if holdsStoreGate { await store.releaseToolOperation() }
        let isError = outcome.isError
        // A successful mutating tool changed persisted app state out from under any
        // open UI (the ⌘K command bar, the docked Chat column, or an external MCP
        // client). Signal the app to reload so views like the Sources sidebar and
        // today's plan don't go stale. Read-only queries and failures don't change state, so they stay quiet.
        if Self.isMutatingTool(name), !isError {
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
        // A listing narrowed to a take says so (MCPTools+Sources.swift).
        return Self.notingScreenRecordNarrowing(outcome, toolName: name)
    }

    /// The tools whose answer is pictures as well as words. Nil for every
    /// other name, which then takes the string dispatch in `executeTool`.
    private func executeMediaTool(name: String, arguments: [String: Any]) async -> MCPDataStore.MediaToolResult? {
        switch name {
        case "inspect_paper_figure": return await store.inspectPaperFigure(arguments: arguments)
        case "show_source_image": return await store.showSourceImage(arguments: arguments)
        // A picture of the Canvas goes out as an image part as well as a file path.
        case "screenshot_canvas": return await store.screenshotCanvas(arguments: arguments)
        default: return await store.executeImageTool(name: name, arguments: arguments)
        }
    }

    /// An argument sent in the wrong JSON shape is read as the shape the
    /// tool's schema declares, when the value says the same thing either way.
    ///
    /// Every handler reads its arguments with a typed cast
    /// (`arguments["keywords"] as? [String] ?? []`), so a model that wrote
    /// `"keywords": "telomere"` for a list, `"limit": "5"` for an integer or
    /// `"include_archived": "true"` for a boolean had the value dropped without
    /// a word: the call then failed as if the argument were missing, or ran
    /// with the default (product owner, 2026-11-10, on a chat whose keyword
    /// search failed mid-answer: "quite often still agents just fail in their
    /// tasks"). Only a value whose type contradicts the schema is touched, and
    /// only at the top level:
    /// - a list declared, a string sent: the JSON list the string spells, or
    ///   the string as a list of one when the list holds strings. It is never
    ///   split on commas, which a phrase may contain.
    /// - an integer or number declared, a numeric string sent: the number.
    /// - a boolean declared, "true" or "false" sent: the boolean.
    /// - a string declared, a list of exactly one string sent: that string.
    static func argumentsShaped(toSchema schema: [String: Any], arguments: [String: Any]) -> [String: Any] {
        guard let properties = schema["properties"] as? [String: Any], !arguments.isEmpty else { return arguments }
        var shaped = arguments
        for (key, value) in arguments {
            guard let property = properties[key] as? [String: Any],
                  let declared = property["type"] as? String else { continue }
            switch declared {
            case "array":
                guard let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.hasPrefix("["),
                   let data = trimmed.data(using: .utf8),
                   let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    shaped[key] = list
                } else if (property["items"] as? [String: Any])?["type"] as? String == "string" {
                    shaped[key] = [trimmed]
                }
            case "integer":
                guard let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let whole = Int(trimmed) {
                    shaped[key] = whole
                } else if let number = Double(trimmed), number.isFinite, number == number.rounded(), abs(number) < 1e15 {
                    shaped[key] = Int(number)
                }
            case "number":
                guard let text = value as? String,
                      let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      number.isFinite else { continue }
                shaped[key] = number
            case "boolean":
                guard let text = value as? String else { continue }
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true": shaped[key] = true
                case "false": shaped[key] = false
                default: continue
                }
            case "string":
                guard let list = value as? [Any], list.count == 1, let only = list[0] as? String else { continue }
                shaped[key] = only
            default:
                continue
            }
        }
        return shaped
    }

    /// An empty optional argument on a read-only tool means the same as leaving
    /// it out.
    ///
    /// Models routinely fill every slot in a schema, and an unused filter comes
    /// through as `""`: `search_sources_semantic` with `added_from ""` was refused
    /// as "not a date" twice in one turn on 2026-09-02, costing two tool rounds
    /// to learn what the schema already said — omit it. A blank or whitespace
    /// string can filter on nothing, so on a tool that only reads, dropping it is
    /// exactly what the caller meant. Mutating tools keep their arguments as
    /// sent: several document `""` as a deliberate value ("pass instructions ""
    /// to clear"), and a required id that is blank should still fail on its own
    /// terms rather than silently become a different call.
    static func normalizedArguments(toolName: String, arguments: [String: Any]) -> [String: Any] {
        guard isReadOnlyTool(toolName) else { return arguments }
        return arguments.filter { _, value in
            guard let text = value as? String else { return true }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Tools that only read state; calling them must not trigger a UI refresh.
    /// This is also the gateway's read-only list (`isReadOnlyTool`, published as
    /// `readOnlyHint`): a tool here may be run again on the hosted mirror after
    /// the Mac ran it, so it must change nothing at all.
    private static let readOnlyToolNames: Set<String> = [
        "list_images", "get_image",
        // The Map's tools read it or change only what is on screen: a lens is
        // not saved until the learner keeps it, in the pane.
        "get_knowledge_map", "apply_map_lens", "clear_map_lens", "focus_map",
        // A check of the layout and a picture of it change nothing on the Canvas.
        "lint_canvas", "screenshot_canvas",
        "list_canvases",
        // The versions of one canvas kept on this Mac, listed.
        "list_canvas_versions",
        "get_canvas_memory",
        // The Atlases made, listed. get_atlas may write a concept in depth.
        "list_atlases",
        "list_running_ai_work",
        // report_connector_status is not here: it records the plugin's health
        // (its Device record, the connector's preferences), so it is a write.
        "get_mcp_status", "get_sync_status", "get_connector_inbox", "list_sources", "list_courses", "get_course", "get_lecture_papers",
        "get_course_quiz",
        "get_source_content", "list_source_actions",
        "inspect_paper_figure", "show_source_image",
        "get_walkthrough", "list_walkthroughs",
        "list_source_highlights", "search_source_highlights",
        "list_meeting_groups", "get_meeting_group", "list_meeting_action_items",
        "get_source_settings",
        "get_memory_review_settings",
        "list_cards",
        "list_source_card_coverage",
        "find_card_sources",
        "list_practices",
        // Today's cards with the wording to ask: nothing is marked asked.
        "get_due_cards",
        // A reading's questions and where each stands in Memory.
        "get_mnemonic_reading",
        "list_unconverted_zoom_recordings",
        "get_automatic_audio_settings",
        "get_day_settings",
        "get_own_router_key",
        "get_ai_usage_report", "get_ai_task_settings",
        "get_app_context",
        "list_notebooks", "get_notebook", "list_notebook_sources", "get_notebook_context",
        "list_notebook_collections",
        "list_notebook_files", "read_notebook_markdown_file", "list_docs", "read_doc",
        // A page's versions on this Mac, and the learner's spaces of pages
        // and their lists of goals and ideas.
        "list_doc_versions", "list_spaces", "list_space_lists",
        // The notes graph's reads. get_daily_note can make the day's empty
        // note when asked, so it is a writer here.
        "get_linked_references", "get_block",
        "list_teams", "list_notebook_tasks",
        // A team's requests for sources, read.
        "list_share_requests",
        "list_assignments", "get_family_plan",
        "get_calendar_events", "get_day_activity",
        "list_doc_chats", "list_doc_comments",
        "list_open_questions",
        "get_schedule", "get_today_sources", "list_learning_goals", "list_goals",
        "get_goal",
        "list_ideas",
        "find_directions", "list_directions", "search_literature",
        "list_skills",
        "get_skill",
        // The notes ForeverLM keeps about the learner's work: a read.
        "list_working_notes",
        "search_sources_semantic", "search_sources_keyword", "list_shows", "filter_sources", "get_review_sessions",
        "get_review_session_transcript", "search_review_sessions",
        "list_review_session_links",
        "list_video_cited_papers",
        // A paper's stored reference list, and its PDF's reference text on request.
        "get_paper_references",
        "list_scheduled_tasks", "get_scheduled_task",
        "read_site_file",
        // The animations kept in the library, and an article's reading view
        // read from its file: neither changes anything.
        "list_animations", "get_article_reading_view",
        "list_slack_channels", "read_slack_channel", "read_slack_thread", "search_slack_messages",
        "get_linear_issue", "search_linear_issues", "list_linear_issues",
        "list_linear_teams", "list_linear_projects", "get_linear_project",
        "list_github_repositories", "get_github_repository", "list_github_files",
        "read_github_file", "search_github_code", "list_github_issues",
        "get_github_issue", "list_github_pull_requests", "get_github_pull_request",
        "list_github_commits",
        "search_notion", "get_notion_page", "list_notion_databases",
        "get_notion_database", "query_notion_database",
        "get_source_audio_status",
    ]

    /// Tools the dispatcher runs without the store gate, because nothing they
    /// run touches the cached connection.
    ///
    /// `callToolDetailed` holds the store's operation gate for a whole call so a
    /// multi-statement read never sees another tool's half-committed state. A
    /// tool whose store work goes through `notebookFileStorage` (the storage
    /// actor, which owns a connection of its own) or `withDB` (a connection
    /// opened for the one query) can neither see nor leave such state, and
    /// holding the gate across its network or model wait would only queue every
    /// other call behind it. A tool belongs here only after checking that
    /// nothing it runs calls `knowledgeStore()`; one that must, around a long
    /// wait, belongs in `selfGatedToolNames`.
    ///
    /// A Slack read is a round trip to the gateway and then to Slack — seconds,
    /// not milliseconds — and the library query it ends with opens a connection
    /// of its own. A Linear read is the same round trip and touches the store
    /// not at all; so is a GitHub read, and so is a Notion read.
    static let storeGateExemptToolNames: Set<String> = [
        // The Map lives in the Studio view model on the main actor; its one
        // library read (the cards' first highlights) goes through the storage
        // actor. Its edits write the learner's layout row through the
        // preference store, never the cached connection.
        "get_knowledge_map", "apply_map_lens", "clear_map_lens", "focus_map",
        "place_on_canvas", "take_off_canvas",
        "create_canvas_region", "update_canvas_region", "delete_canvas_region",
        "draw_canvas_arrow", "update_canvas_arrow", "delete_canvas_arrow",
        "undo_canvas", "keep_map_lens", "set_canvas_display",
        // The parity build's tools act on the same view model: a card's look,
        // Tidy Up and Align, a check of the layout, a picture of it (MCPTools+CanvasParity.swift).
        "update_canvas_card", "arrange_on_canvas", "lint_canvas", "screenshot_canvas",
        // The canvases themselves are layout rows too (MCPTools+Canvases.swift).
        "list_canvases", "create_canvas", "open_canvas", "update_canvas", "delete_canvas",
        // A canvas's versions are files beside knowledge.db and its layout row
        // (MCPTools+CanvasVersions.swift).
        "list_canvas_versions", "save_canvas_version", "restore_canvas_version",
        // The Space's lists are preference rows; their goals and ideas are
        // read through the Studio's storage actor (MCPTools+SpaceLists.swift).
        "list_space_lists", "create_space_list", "update_space_list", "delete_space_list",
        // Ask the Canvas waits on the chat model for seconds; its reads go
        // through the Studio's storage actor (MCPTools+CanvasAsk.swift).
        "ask_canvas",
        // The Atlas lives in the Studio view model; its retrieval, its rows
        // and its model calls go through the storage actor and the AI
        // service, never the cached connection, and a build takes tens of
        // seconds.
        "make_atlas", "get_atlas", "list_atlases", "delete_atlas",
        // Explains a figure it has never seen with a vision model call — tens
        // of seconds — and reads the paper through the storage actor.
        "inspect_paper_figure",
        // A stop must not queue behind the writer it stops, nor a resume
        // behind whatever is writing. None of them touches the cached
        // connection; stopping audio resolves its link token through the
        // storage actor.
        "list_running_ai_work", "cancel_ai_work", "resume_ai_work", "cancel_source_audio_generation",
        // Images live in files under the content root, never knowledge.db
        // (a notebook_id is read through the storage actor), and
        // generate_image waits on an image model for tens of seconds.
        "list_images", "get_image", "generate_image", "save_image", "rename_image", "delete_image",
        "list_slack_channels", "read_slack_channel", "read_slack_thread", "search_slack_messages",
        "get_linear_issue", "search_linear_issues", "list_linear_issues",
        "list_linear_teams", "list_linear_projects", "get_linear_project",
        "list_github_repositories", "get_github_repository", "list_github_files",
        "read_github_file", "search_github_code", "list_github_issues",
        "get_github_issue", "list_github_pull_requests", "get_github_pull_request",
        "list_github_commits",
        "search_notion", "get_notion_page", "list_notion_databases",
        "get_notion_database", "query_notion_database",
        // Long paid tools whose reads and writes all go through the storage
        // actor. On 2026-09-27 an assistant could not read a transcript or
        // save a quiz for minutes while generate_course_quizzes held the gate
        // alone, writing a course's quizzes on the learner's key. A filmed
        // explainer waits on the learner's price dialog before the
        // coordinator films it.
        "generate_course_quizzes", "generate_walkthrough", "generate_explainer_video",
        // The Reader's Find on YouTube and Use Transcript: the episode is read
        // from the Studio and saved through its storage actor, around page
        // reads, YouTube calls and the learner's model.
        "find_podcast_on_youtube", "import_podcast_youtube_transcript",
        // The notes graph reads the Docs, their Markdown, the daily note and
        // the plans, and writes the note and a plan's template, through the
        // storage actor alone (MCPTools+NotesGraph.swift).
        "get_linked_references", "get_block", "get_daily_note", "append_to_daily_note", "get_plan",
        // The card review is the Studio view model's: the chosen cards are
        // read through the storage actor and dealt on the main actor, as
        // open_in_app waits on the window (MCPTools+Cards.swift).
        "practice_cards",
    ]

    /// Tools that wait on the network or a model — most of them long paid ones —
    /// which the dispatcher runs without the store gate because they
    /// take it themselves (`MCPDataStore.withStoreGate`), only around each
    /// stretch that touches the cached connection: reads shared with other
    /// readers, writes alone. Their model calls, transcriptions and downloads
    /// run between those stretches holding nothing, so a call that arrives
    /// meanwhile runs at once instead of waiting for the whole of theirs. A
    /// write that saves what a long wait produced reads its row again inside
    /// its stretch (`saveSourceAfterWait`), so an edit another call made during
    /// the wait is kept. A tool belongs here only after checking that every
    /// `knowledgeStore()` use it runs sits inside such a stretch.
    static let selfGatedToolNames: Set<String> = [
        // The lessons are written through the storage actor; each web page
        // the course cites is imported holding the gate alone, a paper read
        // by its models before the call goes on.
        "generate_course",
        // The quizzes are read and pictured through the storage actor; the
        // slides are captured in extract_video_slides' own stretches.
        "add_course_quiz_pictures",
        // Plans (or accepts an external assistant's plan) through the storage
        // actor and writes the readings there; the book and course are
        // resolved, and the report read, in shared stretches.
        "save_course_textbook_readings", "add_textbook_to_course",
        // The script is written through the storage actor; starting its audio
        // reads the library in one shared stretch.
        "generate_explainer",
        // The Notebook and its sources are read, and the overview saved,
        // through the storage actor; its audio is queued in one shared
        // stretch after the call answers.
        "generate_audio_overview",
        // The Notebook, its team, its sources and Docs are read, and the
        // report saved, through the storage actor; it never touches the
        // cached connection.
        "generate_report",
        // The sources, their decks and cards are read, and the drafts saved,
        // through the storage actor; the drafting runs after the answer.
        "draft_cards",
        // The Canvas is the Studio's, on the main actor; the passages are
        // searched, and the drafts saved, through the storage actor (WP-B2).
        "make_cards_from_canvas",
        // The sources and the reading are read, and each source's questions
        // saved, through the storage actor; the writing runs after the answer.
        "generate_mnemonic_reading",
        // A source's reading levels are read, and written when asked, through
        // the storage actor and the main actor's coordinator: no stretch of it
        // touches the cached connection, and a write waits on the model
        // holding nothing.
        "get_source_levels",
        // The session is read through the storage actor, and the transcript
        // attached in one stretch held alone.
        "transcribe_meeting_recording",
        // Streaming a video's frames, fetching its transcript and a model's
        // reading of its slides hold nothing; what they found is saved in
        // stretches of its own.
        "extract_video_slides", "fetch_video_transcript", "scan_video_for_cited_papers", "find_lecture_papers",
        // A paper's PDF import rewrites its whole row with what the metadata
        // model returned, so each paper holds the gate alone, and calls queued
        // meanwhile run between papers.
        "download_papers_needing_attention", "recheck_paywalled_papers",
        // A local PDF is matched and saved as a pending paper in stretches
        // held alone, around a copy and a text extraction that hold nothing;
        // its models read it after the call answers, holding the store only
        // to save. On 2026-10-12 seven imports sent together held it alone
        // one after another, a minute or more each, and a filter_sources
        // waited behind them until its client timed out. import_local_file
        // routes a paper the same way, a book and a text file through the
        // Studio's storage actor.
        "import_local_pdf_as_paper", "import_local_file",
        // A paper's PDF is found, downloaded, read and looked up in the
        // scholarly indexes holding nothing; the library is asked for the
        // paper in shared stretches, and the pending paper (or a paywalled
        // one) saved in a stretch held alone that asks again. Its models read
        // it after the call answers, as a local PDF's do. A paper the library
        // lists without a PDF takes the download in a stretch held alone, its
        // metadata read included, as attach_pdf_to_paper holds it. The notebook
        // is checked and filed in stretches of their own.
        "import_paper_from_url",
        // A YouTube video's uploader is asked of YouTube holding nothing; the
        // row is then saved in one stretch held alone.
        "add_source",
        // Reads the Notebook and its sources in one shared stretch, searches
        // the web holding nothing, and reads the library's marks in a second
        // shared stretch. It writes nothing.
        "discover_sources",
        // Asks CloudKit which iCloud account this Mac syncs with, up to 4 s on
        // the first call for an account, holding nothing, then reads the
        // search index's coverage in one shared stretch. It writes nothing.
        "get_mcp_status",
    ]

    /// Writing tools whose writes never touch the cached connection.
    ///
    /// Publishing a Doc spends its time on the publishing service and records
    /// the result through the storage actor, which owns a connection of its
    /// own, and changing a passage of a site writes through the same actor;
    /// what these tools do on the cached connection is look up the sources a
    /// page cites. Holding the gate alone for that would queue every
    /// read behind an upload — on 2026-09-18 a `list_teams` waited half a minute
    /// behind a `publish_site` — so they share it like the readers they are on
    /// this connection. A tool belongs here only after checking that every
    /// write it makes goes through `notebookFileStorage`, never `knowledgeStore()`.
    static let sharedGateWritingToolNames: Set<String> = [
        "publish_doc", "unpublish_doc", "replace_site_text",
    ]

    /// How a tool holds the store gate: alone when it writes through the cached
    /// connection, shared with other readers otherwise.
    static func storeGateMode(for name: String) -> MCPStoreOperationMode {
        if !isMutatingTool(name) || sharedGateWritingToolNames.contains(name) { return .shared }
        return .exclusive
    }

    private static let destructiveToolNames: Set<String> = [
        // A region or an arrow gone from the learner's Canvas.
        "delete_canvas_region",
        "delete_canvas_arrow",
        "delete_image",
        "delete_skill",
        // A forgotten note is gone, and its line with it.
        "forget_working_note",
        "unschedule_sources",
        "clear_schedule_day",
        // Activity the app recorded goes for good, on every device.
        "forget_source_activity",
        // A skipped draft is never offered again, and a card from before
        // cards that is skipped is retired, never asked again.
        "triage_cards",
        // Starting a card over retires it and restarts its schedule, and a
        // retired card is never asked again.
        "update_card",
        "delete_notebook",
        "update_course",
        "delete_course",
        "update_notebook_notes",
        "write_notebook_markdown_file",
        "delete_source",
        "remove_source",
        "remove_course_lecture_item",
        // Replaces a quiz in the course, or removes one.
        "save_course_quiz",
        "delete_course_quiz",
        // Replaces the readings a book already has in the course.
        "save_course_textbook_readings", "add_textbook_to_course",
        "remove_all_from_podcast",
        "delete_review_session",
        "refetch_source_content",
        "clear_source_derived_data",
        "update_source",
        "update_source_content",
        "remove_connector_sources",
        "delete_scheduled_task",
        // A team Notebook's task disappears from every member's board.
        "delete_notebook_task",
        // Off ends every member's coverage under this account's plan.
        "set_family_plan",
        // An event leaves the learner's calendar, on every device it syncs to.
        "delete_calendar_event",
        "request_share",
        "list_share_requests",
        "fulfil_share_request",
        "decline_share_request",
        // The learner marked these passages by hand while reading; a deletion
        // throws away their own annotation, not derived state.
        "delete_source_highlight",
        // A walkthrough an assistant authored step by step is not regenerable
        // from anything; removing it is final.
        "delete_walkthrough",
        // The absorbed sessions' rows are archived and their text folded into
        // the survivor; splitting them apart again is by hand.
        "merge_meeting_sessions",
        // An Atlas goes for good; make_atlas writes it again on its model.
        "delete_atlas",
    ]

    private static let openWorldToolNames: Set<String> = [
        "create_x_post",
        // Read live from the learner's Slack workspace through the gateway.
        "list_slack_channels",
        "read_slack_channel",
        "read_slack_thread",
        "search_slack_messages",
        // Read live from the learner's Linear workspace through the gateway.
        "get_linear_issue",
        "search_linear_issues",
        "list_linear_issues",
        "list_linear_teams",
        "list_linear_projects",
        "get_linear_project",
        // Read live from the learner's GitHub repositories through the gateway.
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
        // Read live from the learner's Notion workspace through the gateway.
        "search_notion",
        "get_notion_page",
        "list_notion_databases",
        "get_notion_database",
        "query_notion_database",
        "transcribe_meeting_recording",
        "attach_meeting_artifact",
        "import_meeting_transcript_files",
        // Sends every pending source's narration to the metered speech provider.
        "generate_source_audio",
        // Researches the live web, imports what it cites, and spends credits on
        // every planner and writer call.
        "generate_course",
        // Spends credits on one writer call per quiz, and can rewrite them all.
        "generate_course_quizzes",
        // Streams lecture videos for their slides and spends a call per quiz.
        "add_course_quiz_pictures",
        // Spends credits on the planning call, and replaces the book's readings.
        "add_textbook_to_course",
        // Reads a source and spends credits on the writing call, then may narrate.
        "generate_explainer",
        // Reads a Notebook's sources and spends credits on the writing and any
        // condensing calls, then may narrate.
        "generate_audio_overview",
        // Reads a Notebook's sources and spends credits on the writing and any
        // condensing calls.
        "generate_report",
        // Reads the library on a topic and spends credits on the Atlas call.
        "make_atlas",
        // Reads sources whole and spends credits on drafting their cards.
        "draft_cards",
        // Searches the sources behind the Canvas's Ideas and arrows and
        // spends credits on drafting their cards (WP-B2).
        "make_cards_from_canvas",
        // Reads sources whole and spends credits on writing their questions.
        "generate_mnemonic_reading",
        // Spends dollars on every filmed scene, after the app's price dialog.
        "generate_explainer_video",
        // Reads a paper and spends credits on the writing call and on every
        // animation it draws.
        "generate_walkthrough",
        "add_source",
        "add_sources",
        "import_connector_paper",
        "import_paper_from_url",
        "attach_text_file_to_source",
        "attach_pdf_to_paper",
        "attach_supplementary_pdf",
        "download_papers_needing_attention",
        "recheck_paywalled_papers",
        "follow_youtube_liked_videos",
        "follow_youtube_foreverlm_playlist",
        "import_youtube_playlist",
        // Reads the school's pages as the learner and spends speech-to-text
        // on every lecture's audio.
        "import_teachable_course",
        // Reads the learner's notebook from Google as the learner.
        "import_gemini_notebook",
        "refresh_youtube_sources",
        "extract_paper_metadata",
        "extract_article_metadata",
        "find_podcast_match",
        "resolve_podcast_match",
        // Read the episode's page and YouTube, and rank or format with the learner's model.
        "find_podcast_on_youtube",
        "import_podcast_youtube_transcript",
        "refetch_source_content",
        "import_local_pdf_as_paper",
        "import_local_file",
        "fetch_video_transcript",
        "fetch_source_from_archive",
        // Downloads the paper's PDF; scanning calls a vision model and scholarly APIs.
        "import_video_cited_paper",
        "scan_video_for_cited_papers",
        "scan_meeting_for_mentioned_papers",
        // Reads the article's page (fetching it when there is none) and spends a model call.
        "scan_article_for_linked_sources",
        // Searches the live web with the chat's model and opens the pages it
        // lists to check they are real. Kept out of `readOnlyToolNames` so a
        // client asks before it spends, at the cost of one library reload.
        "discover_sources",
        "find_lecture_papers",
        "ingest_lecture_papers",
        // Downloads storyboards and streams the video to capture slide frames.
        "extract_video_slides",
        // Asks Crossref and OpenAlex about every entry of a paper's list, a minute or
        // more; it reaches the library only through the storage actor.
        "resolve_paper_references",
    ]

    private static func isMutatingTool(_ name: String) -> Bool {
        !isReadOnlyTool(name)
    }

    /// callTool returns error/unknown-tool conditions as plain strings rather than
    /// throwing, so detect them here to avoid refreshing on a no-op.
    private static func isFailureResult(_ result: String) -> Bool {
        result.hasPrefix("Error:") || result.hasPrefix("Unknown tool:")
    }

    private func executeTool(name: String, arguments: [String: Any], hostSessionID: String? = nil, access: MCPAccessContext = .internalFullAccess) async -> String {
        let hostSessionID = hostSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? hostSessionID : nil
        do {
            // The Settings-parity tools (`MCPTools+AppSettings.swift`) dispatch
            // themselves, so this switch does not grow a case per pane control.
            if let result = try await store.executeSettingsParityTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeRunningWorkTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeMnemonicReadingTool(name: name, arguments: arguments) {
                return result
            }
            // Ahead of the Canvas edits, whose names include save and restore.
            if let result = try await store.executeCanvasVersionTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeKnowledgeMapTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeCanvasCatalogTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeSpaceListTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executePaperReferenceTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeCanvasAskTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeSourceLevelsTool(name: name, arguments: arguments) {
                return result
            }
            // Memory on the Canvas (WP-B2)
            if let result = try await store.executeCanvasMemoryTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeAtlasTool(name: name, arguments: arguments) {
                return result
            }
            // A source's draft deck of cards to check is the learner's own
            // memory state, never a Doc (list_docs leaves it out): every tool
            // that takes a doc_id refuses one and names the card tools.
            // The working memory is kept in the background, never as a Doc
            // (`WorkingMemoryRecords`): the working-note tools read and change it.
            if let docID = (arguments["doc_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if MemoryCard.isDraftDeckID(docID) {
                    throw MCPError.invalidInput(MCPDataStore.cardDeckIsNoDocMessage(docID: docID, tool: name))
                }
                if WorkingMemoryRecords.contains(docID) {
                    throw MCPError.invalidInput(MCPDataStore.workingMemoryIsNoDocMessage(docID: docID, tool: name))
                }
            }
            // Notes as a graph: linked references, blocks and daily notes.
            if let result = try await store.executeNotesGraphTool(name: name, arguments: arguments) {
                return result
            }
            switch name {
            case "get_mcp_status": return try await store.getMCPStatus(toolCount: tools.count)
            case "report_connector_status":
                guard access.scope == .ingest else {
                    return "Error: report_connector_status is only available to an ingest-only plugin."
                }
                guard let rawState = arguments["state"] as? String,
                      let state = MCPOAuthProvider.UserPluginHealthState(rawValue: rawState) else {
                    return "Error: state must be healthy, syncing, needs_reconnect, or error."
                }
                let oauthProvider = await MCPOAuthProvider.sharedProvider()
                guard await oauthProvider.reportPluginStatus(
                    clientID: access.clientID,
                    state: state,
                    detail: MCPDataStore.nilIfBlank(arguments["detail"] as? String ?? "")
                ) else {
                    return "Error: this plugin registration no longer exists. Reconnect it in ForeverLM."
                }
                return "Plugin status recorded: \(state.rawValue)"
            case "get_sync_status": return try await store.getSyncStatus()
            case "get_connector_inbox":
                guard access.scope == .ingest else {
                    return "Error: get_connector_inbox is only available to an ingest-only plugin."
                }
                return try store.getConnectorInbox(connectorLabel: access.connectorLabel)
            case "list_sources": return try store.listSources()
            case "list_courses": return try store.listCourses(notebookID: arguments["notebook_id"] as? String)
            case "get_course": return try store.getCourse(courseIdentifier: arguments["course_id"] as? String ?? "")
            case "get_lecture_papers":
                return try store.getLecturePapers(lectureID: arguments["lecture_id"] as? String ?? "")
            case "get_source_content":
                return try await store.getSourceContent(
                    arguments["source_id"] as? String ?? "",
                    recordChatActivity: true
                )
            case "save_source_review_guide":
                return try store.saveSourceReviewGuide(
                    sourceID: arguments["source_id"] as? String ?? "",
                    expectedContentSHA256: arguments["content_sha256"] as? String ?? "",
                    guide: arguments["guide"] as? String ?? ""
                )
            case "list_source_actions": return try store.listSourceActions(arguments["source_id"] as? String ?? "")
            case "list_source_highlights":
                return try store.listSourceHighlights(sourceID: arguments["source_id"] as? String ?? "")
            case "search_source_highlights":
                return try store.searchSourceHighlights(
                    query: arguments["query"] as? String,
                    limit: arguments["limit"] as? Int,
                    color: arguments["color"] as? String
                )
            case "create_source_highlight":
                return try store.createSourceHighlight(
                    sourceID: arguments["source_id"] as? String ?? "",
                    quote: arguments["quote"] as? String ?? "",
                    note: arguments["note"] as? String,
                    color: arguments["color"] as? String,
                    imageURL: arguments["image_url"] as? String,
                    imageAlt: arguments["image_alt"] as? String,
                    sessionID: arguments["session_id"] as? String,
                    hostSessionID: hostSessionID,
                    references: arguments["references"],
                    publicationUpdate: arguments["publication_update"] as? String
                )
            case "update_source_highlight":
                return try store.updateSourceHighlight(
                    highlightID: arguments["highlight_id"] as? String ?? "",
                    note: arguments["note"] as? String,
                    color: arguments["color"] as? String,
                    sessionID: arguments["session_id"] as? String,
                    references: arguments["references"],
                    publicationUpdate: arguments["publication_update"] as? String
                )
            case "delete_source_highlight":
                return try store.deleteSourceHighlight(
                    highlightID: arguments["highlight_id"] as? String ?? ""
                )
            case "list_meeting_groups": return try store.listMeetingGroups()
            case "get_meeting_group": return try store.getMeetingGroup(arguments["group_id"] as? String ?? "")
            case "set_meeting_folder_image":
                return try store.setMeetingFolderImage(
                    groupID: arguments["group_id"] as? String ?? "",
                    imageURL: arguments["image_url"] as? String
                )
            case "set_meeting_schedule":
                return try await store.setMeetingSchedule(
                    groupID: arguments["group_id"] as? String ?? "",
                    weekdays: (arguments["weekdays"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") },
                    start: arguments["start"] as? String,
                    durationMinutes: try MCPDataStore.intArgument(arguments, "duration_minutes"),
                    timezone: arguments["timezone"] as? String,
                    clear: arguments["clear"] as? Bool ?? false
                )
            case "list_meeting_action_items":
                return try await store.listMeetingActionItems(
                    groupID: arguments["group_id"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    latestOnly: arguments["latest_only"] as? Bool ?? false
                )
            case "set_meeting_action_item_done":
                return try await store.setMeetingActionItemDone(
                    itemID: arguments["item_id"] as? String ?? "",
                    done: arguments["done"] as? Bool ?? true
                )
            case "merge_meeting_groups":
                return try store.mergeMeetingGroups(
                    sourceGroupID: arguments["source_group_id"] as? String ?? "",
                    targetGroupID: arguments["target_group_id"] as? String ?? ""
                )
            case "merge_meeting_sessions":
                return try await store.mergeMeetingSessions(
                    groupID: arguments["group_id"] as? String,
                    date: arguments["date"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String]
                )
            case "delete_meeting_group":
                return try await store.deleteMeetingGroup(groupID: arguments["group_id"] as? String ?? "")
            case "list_slack_channels":
                return try await store.listSlackChannels()
            case "read_slack_channel":
                return try await store.readSlackChannel(
                    channelID: arguments["channel_id"] as? String ?? "",
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days")
                )
            case "read_slack_thread":
                return try await store.readSlackThread(
                    channelID: arguments["channel_id"] as? String ?? "",
                    threadTS: (arguments["thread_ts"] as? String)
                        ?? (arguments["thread_ts"] as? Double).map { String(format: "%.6f", $0) }
                        ?? ""
                )
            case "search_slack_messages":
                return try await store.searchSlackMessages(
                    query: arguments["query"] as? String ?? "",
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    channelID: arguments["channel_id"] as? String,
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days"),
                    sort: arguments["sort"] as? String
                )
            case "get_linear_issue":
                return try await store.getLinearIssue(issue: arguments["issue"] as? String ?? "", workspace: arguments["workspace"] as? String)
            case "search_linear_issues":
                return try await store.searchLinearIssues(
                    term: arguments["term"] as? String ?? "",
                    teamKey: arguments["team_key"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "list_linear_issues":
                return try await store.listLinearIssues(
                    teamKey: arguments["team_key"] as? String,
                    stateType: arguments["state_type"] as? String,
                    assignedToMe: (arguments["assigned_to_me"] as? Bool)
                        ?? (arguments["assigned_to_me"] as? String).map { ["true", "1", "yes"].contains($0.lowercased()) },
                    updatedSinceDays: try MCPDataStore.intArgument(arguments, "updated_since_days"),
                    project: arguments["project"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "list_linear_teams":
                return try await store.listLinearTeams(workspace: arguments["workspace"] as? String)
            case "list_linear_projects":
                return try await store.listLinearProjects(
                    teamKey: arguments["team_key"] as? String,
                    statusType: arguments["status_type"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "get_linear_project":
                return try await store.getLinearProject(project: arguments["project"] as? String ?? "", workspace: arguments["workspace"] as? String)
            case "list_github_repositories":
                return try await store.listGitHubRepositories(
                    query: arguments["query"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "get_github_repository":
                return try await store.getGitHubRepository(
                    repository: arguments["repository"] as? String ?? "",
                    ref: arguments["ref"] as? String
                )
            case "list_github_files":
                return try await store.listGitHubFiles(
                    repository: arguments["repository"] as? String ?? "",
                    path: arguments["path"] as? String,
                    ref: arguments["ref"] as? String,
                    recursive: (arguments["recursive"] as? Bool)
                        ?? (arguments["recursive"] as? String).map { ["true", "1", "yes"].contains($0.lowercased()) }
                )
            case "read_github_file":
                return try await store.readGitHubFile(
                    repository: arguments["repository"] as? String ?? "",
                    path: arguments["path"] as? String ?? "",
                    ref: arguments["ref"] as? String
                )
            case "search_github_code":
                return try await store.searchGitHubCode(
                    repository: arguments["repository"] as? String ?? "",
                    query: arguments["query"] as? String ?? "",
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "list_github_issues":
                return try await store.listGitHubIssues(
                    repository: arguments["repository"] as? String ?? "",
                    state: arguments["state"] as? String,
                    labels: arguments["labels"] as? String,
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days"),
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "get_github_issue":
                return try await store.getGitHubIssue(
                    repository: arguments["repository"] as? String ?? "",
                    number: try MCPDataStore.intArgument(arguments, "number")
                )
            case "list_github_pull_requests":
                return try await store.listGitHubPullRequests(
                    repository: arguments["repository"] as? String ?? "",
                    state: arguments["state"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "get_github_pull_request":
                return try await store.getGitHubPullRequest(
                    repository: arguments["repository"] as? String ?? "",
                    number: try MCPDataStore.intArgument(arguments, "number")
                )
            case "list_github_commits":
                return try await store.listGitHubCommits(
                    repository: arguments["repository"] as? String ?? "",
                    ref: arguments["ref"] as? String,
                    path: arguments["path"] as? String,
                    sinceDays: try MCPDataStore.intArgument(arguments, "since_days"),
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "search_notion":
                return try await store.searchNotion(
                    query: arguments["query"] as? String,
                    kind: arguments["kind"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "get_notion_page":
                return try await store.getNotionPage(
                    page: arguments["page"] as? String ?? "",
                    includeContent: (arguments["include_content"] as? Bool)
                        ?? (arguments["include_content"] as? String).map { !["false", "0", "no"].contains($0.lowercased()) },
                    workspace: arguments["workspace"] as? String
                )
            case "list_notion_databases":
                return try await store.listNotionDatabases(
                    query: arguments["query"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    workspace: arguments["workspace"] as? String
                )
            case "get_notion_database":
                return try await store.getNotionDatabase(database: arguments["database"] as? String ?? "", workspace: arguments["workspace"] as? String)
            case "query_notion_database":
                return try await store.queryNotionDatabase(
                    database: arguments["database"] as? String ?? "",
                    filter: arguments["filter"],
                    sorts: arguments["sorts"],
                    limit: try MCPDataStore.intArgument(arguments, "limit"),
                    cursor: arguments["cursor"] as? String,
                    workspace: arguments["workspace"] as? String
                )
            case "create_x_post":
                let posted = try await XBookmarkService.shared.createPost(
                    text: arguments["text"] as? String ?? "",
                    replyToPostId: arguments["reply_to_post_id"] as? String,
                    account: arguments["account"] as? String
                )
                return try store.jsonString([
                    "posted": true,
                    "post_id": posted.postId,
                    "url": posted.url,
                    "posted_as": posted.account.displayLabel,
                ] as [String: Any])
            case "attach_meeting_artifact":
                return try store.attachMeetingArtifact(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String ?? "",
                    kindString: arguments["kind"] as? String
                )
            case "transcribe_meeting_recording":
                return try await store.transcribeMeetingRecording(
                    sourceID: arguments["source_id"] as? String ?? ""
                )
            case "generate_source_audio":
                return try await store.generateSourceAudio(
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    bookIDs: arguments["book_ids"] as? [String] ?? [],
                    sourceTypeNames: arguments["source_types"] as? [String] ?? [],
                    confirmCost: arguments["confirm_cost"] as? Bool ?? false,
                    allowUnsupportedLanguages: arguments["allow_unsupported_languages"] as? Bool ?? false,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                        ?? MCPRunningWork.defaultSpendLimitUSD
                )
            case "get_source_audio_status":
                return try await store.getSourceAudioStatus(
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "cancel_source_audio_generation":
                return try await store.cancelSourceAudioGeneration(
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    all: arguments["all"] as? Bool ?? false
                )
            case "get_automatic_audio_settings":
                return try await store.getAutomaticAudioSettings()
            case "set_automatic_audio_settings":
                return try await store.setAutomaticAudioSettings(
                    kind: arguments["kind"] as? String,
                    enabled: arguments["enabled"] as? Bool,
                    filter: arguments["filter"] as? String,
                    allowPaidVoices: arguments["allow_paid_voices"] as? Bool
                )
            case "import_meeting_transcript_files":
                return try await store.importMeetingTranscriptFiles(
                    groupTitle: arguments["group_title"] as? String ?? "",
                    folderPath: arguments["folder_path"] as? String ?? "",
                    source: arguments["source"] as? String
                )
            case "list_scheduled_tasks":
                return try store.listScheduledTasks(
                    includeRuns: arguments["include_runs"] as? Bool ?? false
                )
            case "get_scheduled_task":
                return try store.getScheduledTask(taskID: arguments["task_id"] as? String)
            case "create_scheduled_task":
                return try store.createScheduledTask(
                    title: arguments["title"] as? String,
                    instruction: arguments["instruction"] as? String,
                    cadence: arguments["cadence"] as? String,
                    hour: arguments["hour"] as? Int,
                    minute: arguments["minute"] as? Int,
                    weekday: arguments["weekday"] as? Int,
                    dayOfMonth: arguments["day_of_month"] as? Int,
                    date: arguments["date"] as? String,
                    timeZone: arguments["time_zone"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    enabled: arguments["enabled"] as? Bool
                )
            case "update_scheduled_task":
                return try store.updateScheduledTask(
                    taskID: arguments["task_id"] as? String,
                    title: arguments["title"] as? String,
                    instruction: arguments["instruction"] as? String,
                    cadence: arguments["cadence"] as? String,
                    hour: arguments["hour"] as? Int,
                    minute: arguments["minute"] as? Int,
                    weekday: arguments["weekday"] as? Int,
                    dayOfMonth: arguments["day_of_month"] as? Int,
                    date: arguments["date"] as? String,
                    timeZone: arguments["time_zone"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    clearNotebook: arguments["clear_notebook"] as? Bool ?? false,
                    sourceIDs: arguments["source_ids"] as? [String],
                    enabled: arguments["enabled"] as? Bool
                )
            case "run_scheduled_task_now":
                return try store.runScheduledTaskNow(taskID: arguments["task_id"] as? String)
            case "delete_scheduled_task":
                return try store.deleteScheduledTask(taskID: arguments["task_id"] as? String)
            case "get_app_context": return try store.getAppContext()
            case "list_notebooks":
                return try store.listNotebooks(includeCompleted: arguments["include_completed"] as? Bool ?? false)
            case "create_notebook":
                return try await store.createNotebook(
                    title: arguments["title"] as? String,
                    // instructions is the advertised name; description is honored for
                    // clients holding a pre-rename tool list.
                    description: (arguments["instructions"] ?? arguments["description"]) as? String,
                    summary: arguments["summary"] as? String,
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String ?? "",
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool ?? false,
                    researchQuestions: arguments["research_questions"] as? [String],
                    repository: arguments["repository"] as? String,
                    allowDuplicate: arguments["allow_duplicate"] as? Bool ?? false,
                    hostSessionID: hostSessionID
                )
            case "update_notebook":
                return try await store.updateNotebook(
                    notebookID: arguments["notebook_id"] as? String,
                    title: arguments["title"] as? String,
                    description: (arguments["instructions"] ?? arguments["description"]) as? String,
                    summary: arguments["summary"] as? String,
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String,
                    openEnded: arguments["open_ended"] as? Bool,
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool,
                    researchQuestions: arguments["research_questions"] as? [String],
                    relatedNotebookIDs: arguments["related_notebook_ids"] as? [String],
                    repository: arguments["repository"] as? String,
                    status: arguments["status"] as? String,
                    thinkFirst: arguments["think_first"] as? String
                )
            case "get_notebook":
                return try store.getNotebookDetail(notebookID: arguments["notebook_id"] as? String)
            case "delete_notebook":
                return try store.deleteNotebook(
                    notebookID: arguments["notebook_id"] as? String,
                    deleteChats: arguments["delete_chats"] as? Bool ?? false
                )
            case "add_notebook_sources":
                return try await store.addNotebookSources(
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "list_notebook_sources":
                return try store.listNotebookSources(
                    notebookID: arguments["notebook_id"] as? String
                )
            case "discover_sources":
                return try await store.discoverSources(
                    notebookID: arguments["notebook_id"] as? String,
                    query: arguments["query"] as? String,
                    count: arguments["count"] as? Int,
                    sourceIDs: arguments["source_ids"] as? [String]
                )
            case "reorder_notebook_sources":
                return try store.reorderNotebookSources(
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "set_notebook_source_selection":
                return try await store.setNotebookSourceSelection(
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    contextNotebookIDs: arguments["context_notebook_ids"] as? [String] ?? [],
                    mode: arguments["mode"] as? String ?? ""
                )
            case "list_notebook_collections":
                return try store.listNotebookCollections()
            case "update_notebook_collection":
                return try await store.updateNotebookCollection(
                    action: arguments["action"] as? String ?? "",
                    collectionID: arguments["collection_id"] as? String,
                    name: arguments["name"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String]
                )
            case "get_notebook_context":
                return try await store.getNotebookContext(
                    notebookID: arguments["notebook_id"] as? String,
                    maxSourceChars: arguments["max_source_chars"] as? Int,
                    includeEmergentState: arguments["include_emergent_state"] as? Bool,
                    includeSourceContent: arguments["include_source_content"] as? Bool
                )
            case "list_notebook_files":
                return try await store.listNotebookFiles(
                    notebookID: arguments["notebook_id"] as? String
                )
            case "list_teams":
                return try await store.listTeams()
            case "create_team":
                return try await store.createTeam(name: arguments["name"] as? String)
            case "share_with_team":
                return try await store.shareWithTeam(
                    teamID: arguments["team_id"] as? String,
                    kind: arguments["kind"] as? String,
                    ids: arguments["ids"] as? [String] ?? [],
                    includeSources: arguments["include_sources"] as? Bool,
                    includeDocs: arguments["include_docs"] as? Bool,
                    includeChats: arguments["include_chats"] as? Bool,
                    includeCitedSources: arguments["include_cited_sources"] as? Bool,
                    rightsAnswer: MCPDataStore.SharingRightsAnswer(arguments["rights_affirmed_by_learner"])
                )
            case "share_notebook":
                return try await store.shareNotebook(
                    notebookID: arguments["notebook_id"] as? String,
                    rightsAnswer: MCPDataStore.SharingRightsAnswer(arguments["rights_affirmed_by_learner"]),
                    teamID: arguments["team_id"] as? String
                )
            case "request_share":
                return try await store.requestShare(
                    teamID: arguments["team_id"] as? String,
                    url: arguments["url"] as? String,
                    title: arguments["title"] as? String,
                    docID: arguments["doc_id"] as? String
                )
            case "list_share_requests":
                return try await store.listShareRequests(
                    teamID: arguments["team_id"] as? String,
                    status: arguments["status"] as? String
                )
            case "fulfil_share_request":
                return try await store.fulfilShareRequest(
                    requestID: arguments["request_id"] as? String,
                    rightsAnswer: MCPDataStore.SharingRightsAnswer(arguments["rights_affirmed_by_learner"])
                )
            case "decline_share_request":
                return try await store.declineShareRequest(requestID: arguments["request_id"] as? String)
            case "assign_to_member":
                return try await store.assignToMember(
                    teamID: arguments["team_id"] as? String,
                    member: arguments["member"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String],
                    docID: arguments["doc_id"] as? String,
                    dueDate: arguments["due_date"] as? String,
                    notes: arguments["notes"] as? String
                )
            case "list_assignments":
                return try await store.listAssignments(
                    teamID: arguments["team_id"] as? String,
                    mine: arguments["mine"] as? Bool,
                    includeDone: arguments["include_done"] as? Bool
                )
            case "get_family_plan":
                return try await store.getFamilyPlan()
            case "set_family_plan":
                return try await store.setFamilyPlan(
                    teamID: arguments["team_id"] as? String,
                    enabled: arguments["enabled"] as? Bool
                )
            case "connect_family_member_key":
                return try await store.connectFamilyMemberKey(
                    teamID: arguments["team_id"] as? String,
                    member: arguments["member"] as? String
                )
            case "list_notebook_tasks":
                return try await store.listNotebookTasks(
                    notebookID: arguments["notebook_id"] as? String,
                    status: arguments["status"] as? String,
                    assignee: arguments["assignee"] as? String
                )
            case "create_notebook_task":
                return try await store.createNotebookTask(
                    notebookID: arguments["notebook_id"] as? String,
                    title: arguments["title"] as? String,
                    notes: arguments["notes"] as? String,
                    status: arguments["status"] as? String,
                    assigneeRecordName: arguments["assignee_record_name"] as? String,
                    dueDate: arguments["due_date"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    docID: arguments["doc_id"] as? String
                )
            case "update_notebook_task":
                return try await store.updateNotebookTask(
                    taskID: arguments["task_id"] as? String,
                    title: arguments["title"] as? String,
                    notes: arguments["notes"] as? String,
                    status: arguments["status"] as? String,
                    assigneeRecordName: arguments["assignee_record_name"] as? String,
                    dueDate: arguments["due_date"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    docID: arguments["doc_id"] as? String
                )
            case "delete_notebook_task":
                return try await store.deleteNotebookTask(taskID: arguments["task_id"] as? String)
            case "get_calendar_events":
                return try await store.getCalendarEvents(
                    date: arguments["date"] as? String,
                    days: try MCPDataStore.intArgument(arguments, "days")
                )
            case "create_calendar_event":
                return try await store.createCalendarEvent(arguments: arguments)
            case "update_calendar_event":
                return try await store.updateCalendarEvent(arguments: arguments)
            case "delete_calendar_event":
                return try await store.deleteCalendarEvent(arguments: arguments)
            case "get_day_activity":
                return try await store.getDayActivity(date: arguments["date"] as? String)
            case "delete_day_activity":
                return try await store.deleteDayActivity(activityID: arguments["activity_id"] as? String)
            case "get_learning_bout":
                return try await store.getLearningBout(date: arguments["date"] as? String)
            case "start_learning_bout":
                return try await store.startLearningBout(
                    eventID: arguments["event_id"] as? String,
                    occurrenceDate: arguments["occurrence_date"] as? String,
                    title: arguments["title"] as? String,
                    minutes: try MCPDataStore.intArgument(arguments, "minutes"),
                    notebookID: arguments["notebook_id"] as? String,
                    sourceIDs: MCPDataStore.sourceIDArguments(arguments)
                )
            case "end_learning_bout":
                return try await store.endLearningBout(boutID: arguments["bout_id"] as? String)
            case "write_up_learning_bout":
                return try await store.writeUpLearningBout(
                    boutID: arguments["bout_id"] as? String,
                    learned: arguments["learned"] as? String,
                    unclear: arguments["unclear"] as? String,
                    breakMinutes: try MCPDataStore.intArgument(arguments, "break_minutes")
                )
            case "set_learning_bout_break":
                return try await store.setLearningBoutBreak(
                    boutID: arguments["bout_id"] as? String,
                    running: arguments["running"] as? Bool ?? true,
                    minutes: try MCPDataStore.intArgument(arguments, "minutes")
                )
            case "abandon_learning_bout":
                return try await store.abandonLearningBout(boutID: arguments["bout_id"] as? String)
            case "list_docs":
                return try await store.listArtifacts(notebookID: arguments["notebook_id"] as? String)
            case "create_doc":
                return try await store.createArtifact(
                    title: arguments["title"] as? String ?? "",
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? [],
                    markdown: arguments["markdown"] as? String ?? "",
                    isDraft: arguments["is_draft"] as? Bool ?? false
                )
            case "read_doc":
                return try await store.readArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    start: arguments["start"] as? Int,
                    length: arguments["length"] as? Int,
                    resolveReferences: arguments["resolve_references"] as? Bool ?? false
                )
            case "list_doc_chats":
                return try await store.listArtifactChats(
                    artifactID: arguments["doc_id"] as? String ?? ""
                )
            case "link_doc_passage_to_chat":
                return try await store.linkArtifactPassageToChat(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    quote: arguments["quote"] as? String ?? "",
                    sectionTitle: arguments["section_title"] as? String ?? ""
                )
            case "unlink_doc_chat":
                return try await store.unlinkArtifactChat(
                    linkID: arguments["link_id"] as? String ?? ""
                )
            case "list_doc_comments":
                return try await store.listDocComments(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    includeResolved: arguments["include_resolved"] as? Bool ?? true
                )
            case "comment_on_doc":
                return try await store.commentOnDoc(
                    artifactID: arguments["doc_id"] as? String,
                    quote: arguments["quote"] as? String,
                    body: arguments["body"] as? String ?? "",
                    replyTo: arguments["reply_to"] as? String
                )
            case "update_doc_comment":
                return try await store.updateDocComment(
                    commentID: arguments["comment_id"] as? String ?? "",
                    body: arguments["body"] as? String,
                    resolved: arguments["resolved"] as? Bool
                )
            case "delete_doc_comment":
                return try await store.deleteDocComment(
                    commentID: arguments["comment_id"] as? String ?? "",
                    wholeThread: arguments["whole_thread"] as? Bool ?? false
                )
            case "write_doc":
                return try await store.writeArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    markdown: arguments["markdown"] as? String ?? "",
                    expectedRevision: arguments["expected_revision"] as? String ?? "",
                    publish: arguments["publish"] as? Bool ?? false
                )
            case "edit_doc":
                let rawEdits = arguments["edits"] as? [[String: Any]] ?? []
                let edits = rawEdits.map { edit in
                    MCPDataStore.ArtifactEdit(
                        find: edit["find"] as? String ?? "",
                        replace: edit["replace"] as? String ?? "",
                        replaceAll: edit["replace_all"] as? Bool ?? false
                    )
                }
                return try await store.editArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    edits: edits,
                    append: arguments["append"] as? String,
                    expectedRevision: arguments["expected_revision"] as? String ?? "",
                    publish: arguments["publish"] as? Bool ?? false
                )
            case "update_doc":
                return try await store.updateArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String],
                    isDraft: arguments["is_draft"] as? Bool,
                    isArchived: arguments["is_archived"] as? Bool,
                    isHidden: arguments["is_hidden"] as? Bool
                )
            case "delete_doc":
                return try await store.deleteArtifact(artifactID: arguments["doc_id"] as? String ?? "")
            case "list_doc_versions":
                return try await store.listDocVersions(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    versionID: arguments["version_id"] as? String,
                    start: arguments["start"] as? Int,
                    length: arguments["length"] as? Int
                )
            case "restore_doc_version":
                return try await store.restoreDocVersion(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    versionID: arguments["version_id"] as? String ?? "",
                    expectedRevision: arguments["expected_revision"] as? String,
                    publish: arguments["publish"] as? Bool ?? false
                )
            case "list_spaces":
                return try await store.listPageSpaces()
            case "update_space":
                return try await store.updatePageSpace(
                    action: arguments["action"] as? String ?? "",
                    spaceID: arguments["space_id"] as? String,
                    name: arguments["name"] as? String,
                    docIDs: arguments["doc_ids"] as? [String]
                )
            case "link_page", "link_google_doc":
                return try await store.linkPageArtifact(
                    urlString: arguments["url"] as? String ?? "",
                    title: arguments["title"] as? String,
                    text: arguments["text"] as? String,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? []
                )
            case "unlink_page", "unlink_google_doc":
                return try await store.unlinkPageArtifact(artifactID: arguments["doc_id"] as? String ?? "")
            case "adopt_page":
                return try await store.adoptPageArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    markdown: arguments["markdown"] as? String,
                    readers: arguments["readers"] as? [String],
                    slug: arguments["slug"] as? String
                )
            case "publish_doc":
                if arguments["password"] != nil {
                    throw MCPError.invalidInput("Pages are no longer shared with a password. Pass readers, a list of email addresses, instead.")
                }
                return try await store.publishArtifact(
                    artifactID: arguments["doc_id"] as? String ?? "",
                    readers: arguments["readers"] as? [String],
                    slug: arguments["slug"] as? String
                )
            case "unpublish_doc":
                return try await store.unpublishArtifact(artifactID: arguments["doc_id"] as? String ?? "")
            case "save_site":
                return try await store.saveSite(
                    site: arguments["site"] as? String,
                    title: arguments["title"] as? String,
                    html: arguments["html"] as? String,
                    files: arguments["files"] as? [Any],
                    repository: arguments["repository"] as? String,
                    repositoryPath: arguments["repository_path"] as? String,
                    ref: arguments["ref"] as? String,
                    removeFiles: arguments["remove_files"] as? [String] ?? [],
                    replaceAll: arguments["replace_all"] as? Bool ?? false,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? []
                )
            case "read_site_file":
                return try await store.readSiteFile(
                    site: arguments["site"] as? String ?? "",
                    path: arguments["path"] as? String
                )
            case "replace_site_text":
                return try await store.replaceSiteText(
                    site: arguments["site"] as? String ?? "",
                    find: arguments["find"] as? String ?? "",
                    replace: arguments["replace"] as? String ?? "",
                    path: arguments["path"] as? String
                )
            case "save_animation":
                return try await store.saveAnimation(
                    animation: arguments["animation"] as? String,
                    title: arguments["title"] as? String,
                    description: arguments["description"] as? String,
                    html: arguments["html"] as? String,
                    files: arguments["files"] as? [Any],
                    sources: arguments["sources"] as? [String] ?? [],
                    removeFiles: arguments["remove_files"] as? [String] ?? [],
                    replaceAll: arguments["replace_all"] as? Bool ?? false,
                    homeNotebookID: arguments["home_notebook_id"] as? String,
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? []
                )
            case "list_animations":
                return try await store.listAnimations(
                    sourceID: arguments["source_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "delete_animation":
                return try await store.deleteAnimation(animation: arguments["animation"] as? String ?? "")
            case "list_source_artifacts":
                return try await store.listSourceArtifacts(sourceID: arguments["source_id"] as? String ?? "")
            case "read_notebook_markdown_file":
                return try await store.readNotebookMarkdownFile(
                    notebookID: arguments["notebook_id"] as? String,
                    relativePath: arguments["path"] as? String ?? ""
                )
            case "write_notebook_markdown_file":
                return try await store.writeNotebookMarkdownFile(
                    notebookID: arguments["notebook_id"] as? String,
                    relativePath: arguments["path"] as? String ?? "",
                    markdown: arguments["markdown"] as? String ?? "",
                    expectedRevision: arguments["expected_revision"] as? String
                )
            case "list_open_questions":
                return try store.listOpenQuestions(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    includeResolved: arguments["include_resolved"] as? Bool,
                    status: arguments["status"] as? String
                )
            case "create_open_question":
                return try store.createOpenQuestion(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    summary: arguments["summary"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String,
                    severity: clampUnitInterval(optional: arguments["severity"] as? Double),
                    status: arguments["status"] as? String
                )
            case "update_open_question":
                return try store.updateOpenQuestion(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    questionID: arguments["question_id"] as? String ?? "",
                    summary: arguments["summary"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    severity: clampUnitInterval(optional: arguments["severity"] as? Double),
                    status: arguments["status"] as? String,
                    clearSourceID: arguments["clear_source_link"] as? Bool ?? false
                )
            case "update_notebook_notes", "append_notebook_notes":
                return try store.updateNotebookNotes(
                    notebookID: arguments["notebook_id"] as? String,
                    markdown: arguments["markdown"] as? String ?? arguments["notes"] as? String ?? "",
                    append: name == "append_notebook_notes"
                )
            case "split_notebook":
                return try store.splitNotebook(
                    notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                    splits: arguments["splits"] as? [[String: Any]] ?? [],
                    keepParent: arguments["keep_parent"] as? Bool ?? true
                )
            case "merge_notebooks":
                return try store.mergeNotebooks(
                    notebookIDs: arguments["notebook_ids"] as? [String] ?? [],
                    title: arguments["title"] as? String,
                    mergeNotes: arguments["merge_notes"] as? Bool ?? true
                )
            case "get_schedule":
                return try store.getSchedule(
                    goalID: arguments["goal_id"] as? String,
                    includeCompleted: arguments["include_completed"] as? Bool ?? true
                )
            case "get_today_sources":
                return try store.getTodaySources(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String,
                    dateBasis: arguments["date_basis"] as? String,
                    activityKind: arguments["activity_kind"] as? String,
                    includeCompleted: arguments["include_completed"] as? Bool ?? false,
                    maxCharsPerSource: arguments["max_chars_per_source"] as? Int
                )
            case "assign_sources_to_day":
                return try await store.assignSourcesToDay(
                    goalID: arguments["goal_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dateString: arguments["date"] as? String ?? ""
                )
            case "unschedule_sources":
                return try store.unscheduleSources(
                    goalID: arguments["goal_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "forget_source_activity":
                return try store.forgetSourceActivity(
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dateString: arguments["date"] as? String
                )
            case "clear_schedule_day":
                return try store.clearScheduleDay(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String ?? "",
                    includeCompleted: arguments["include_completed"] as? Bool ?? false
                )
            case "mark_schedule_day_done":
                return try store.markScheduleDayDone(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String ?? ""
                )
            case "set_source_completion":
                return try store.setSourceCompletion(
                    goalID: arguments["goal_id"] as? String,
                    sourceID: arguments["source_id"] as? String ?? "",
                    isCompleted: arguments["is_completed"] as? Bool ?? false
                )
            case "create_learning_goal":
                return try await store.createCompanionLearningGoal(
                    title: arguments["title"] as? String ?? "",
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String ?? "",
                    startDateString: arguments["start_date"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool ?? true,
                    notebookID: arguments["notebook_id"] as? String,
                    artifactID: arguments["artifact_id"] as? String
                )
            case "list_learning_goals":
                return try store.listCompanionLearningGoals(includeCompleted: arguments["include_completed"] as? Bool ?? false)
            case "list_goals":
                return try store.listNotebookGoals(
                    notebookID: arguments["notebook_id"] as? String,
                    includeCompleted: arguments["include_completed"] as? Bool ?? false
                )
            case "update_learning_goal":
                return try await store.updateLearningGoal(
                    goalID: arguments["goal_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    description: arguments["description"] as? String,
                    topic: arguments["topic"] as? String,
                    endDateString: arguments["end_date"] as? String,
                    dailyTarget: arguments["daily_target"] as? Int,
                    discover: arguments["discover"] as? Bool,
                    notebookID: arguments["notebook_id"] as? String,
                    statusString: arguments["status"] as? String,
                    artifactID: arguments["artifact_id"] as? String
                )
            case "list_ideas":
                return try store.listIdeas(
                    includeArchived: arguments["include_archived"] as? Bool ?? true,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "list_skills":
                return try store.listSkills()
            case "get_skill":
                return try store.getSkill(
                    name: arguments["name"] as? String,
                    skillID: arguments["skill_id"] as? String
                )
            case "save_skill":
                return try store.saveSkill(
                    skillID: arguments["skill_id"] as? String,
                    name: arguments["name"] as? String,
                    description: arguments["description"] as? String,
                    instructions: arguments["instructions"] as? String,
                    skillMarkdown: arguments["skill_markdown"] as? String
                )
            case "delete_skill":
                return try store.deleteSkill(skillID: arguments["skill_id"] as? String ?? "")
            case "list_working_notes":
                return try await store.listWorkingNotes(arguments: arguments)
            case "save_working_note":
                return try await store.saveWorkingNote(arguments: arguments)
            case "update_working_note":
                return try await store.updateWorkingNote(arguments: arguments)
            case "forget_working_note":
                return try await store.forgetWorkingNote(arguments: arguments)
            case "create_idea":
                return try store.createIdea(
                    title: arguments["title"] as? String ?? "",
                    notes: arguments["notes"] as? String,
                    links: arguments["links"] as? [[String: Any]] ?? []
                )
            case "update_idea":
                return try store.updateIdea(
                    ideaID: arguments["idea_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    notes: arguments["notes"] as? String,
                    statusString: arguments["status"] as? String
                )
            case "link_idea":
                return try store.linkIdea(
                    ideaID: arguments["idea_id"] as? String ?? "",
                    kindString: arguments["kind"] as? String ?? "",
                    targetIDs: arguments["target_ids"] as? [String] ?? []
                )
            case "unlink_idea":
                return try store.unlinkIdea(
                    ideaID: arguments["idea_id"] as? String ?? "",
                    kindString: arguments["kind"] as? String ?? "",
                    targetIDs: arguments["target_ids"] as? [String] ?? []
                )
            case "delete_idea":
                return try store.deleteIdea(ideaID: arguments["idea_id"] as? String ?? "")
            case "find_directions":
                return try await store.findDirections(
                    homeID: arguments["home_id"] as? String ?? "",
                    focus: arguments["focus"] as? String
                )
            case "search_literature":
                return try await store.searchLiterature(
                    query: arguments["query"] as? String ?? "",
                    fromYear: arguments["from_year"] as? Int,
                    toYear: arguments["to_year"] as? Int,
                    preprintsOnly: arguments["preprints_only"] as? Bool ?? false,
                    sortString: arguments["sort"] as? String,
                    limit: arguments["limit"] as? Int ?? 10
                )
            case "propose_directions":
                return try store.proposeDirections(
                    homeID: arguments["home_id"] as? String ?? "",
                    rawDirections: arguments["directions"] as? [[String: Any]] ?? [],
                    sessionID: arguments["session_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "list_directions":
                return try store.listDirections(
                    homeID: arguments["home_id"] as? String,
                    statusString: arguments["status"] as? String
                )
            case "update_direction":
                return try store.updateDirection(
                    directionID: arguments["direction_id"] as? String ?? "",
                    arguments: arguments
                )
            case "delete_direction":
                return try store.deleteDirection(directionID: arguments["direction_id"] as? String ?? "")
            case "get_goal":
                return try store.getGoal(goalID: arguments["goal_id"] as? String ?? "")
            case "add_goal_sources":
                return try await store.addGoalSources(
                    goalID: arguments["goal_id"] as? String ?? "",
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "reorder_goals":
                return try store.reorderGoals(goalIDs: arguments["goal_ids"] as? [String] ?? [])
            case "delete_learning_goal":
                return try store.deleteLearningGoal(goalID: arguments["goal_id"] as? String ?? "")
            case "daily_quiz":
                return try await store.dailyQuiz(
                    goalID: arguments["goal_id"] as? String,
                    dateString: arguments["date"] as? String,
                    startSession: arguments["start_session"] as? Bool ?? true,
                    hostSessionID: hostSessionID
                )
            case "daily_review":
                return try await store.dailyReview(
                    goalID: arguments["goal_id"] as? String,
                    startSession: arguments["start_session"] as? Bool ?? true,
                    hostSessionID: hostSessionID
                )
            case "memory_review":
                return try await store.memoryReview(
                    goalID: arguments["goal_id"] as? String,
                    limit: arguments["limit"] as? Int,
                    startSession: arguments["start_session"] as? Bool ?? true,
                    operationID: arguments["operation_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "cohort_review":
                return try await store.cohortReview(
                    startSession: arguments["start_session"] as? Bool ?? true,
                    goalID: arguments["goal_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "get_memory_review_settings":
                return try await store.getMemoryReviewSettings()
            case "set_memory_review_settings":
                return try await store.setMemoryReviewSettings(
                    budgetMinutes: arguments["budget_minutes"] as? Int,
                    prepareDaily: arguments["prepare_daily"] as? Bool,
                    readyByHour: arguments["ready_by_hour"] as? Int,
                    newCardsPerDay: arguments["new_cards_per_day"] as? Int,
                    autoDraftCards: arguments["auto_draft_cards"] as? Bool,
                    draftNudges: arguments["draft_nudges"] as? Bool
                )
            case "draft_cards":
                return try await store.draftCards(arguments: arguments)
            case "save_card_drafts":
                return try await store.saveCardDrafts(
                    cards: arguments["cards"] as? [[String: Any]] ?? [],
                    keptByDefault: arguments["kept_by_default"] as? Bool ?? false
                )
            case "list_cards":
                return try await store.listCards(
                    status: arguments["status"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    sourceID: arguments["source_id"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "list_source_card_coverage":
                return try await store.listSourceCardCoverage(
                    scope: arguments["scope"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "find_card_sources":
                return try await store.findCardSources(
                    cardID: arguments["card_id"] as? String,
                    question: arguments["question"] as? String,
                    answer: arguments["answer"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    notebookID: arguments["notebook_id"] as? String
                )
            case "triage_cards":
                return try await store.triageCards(
                    decisions: arguments["decisions"] as? [[String: Any]] ?? [],
                    keepSourceIDs: arguments["keep_source_ids"] as? [String] ?? [],
                    skipSourceIDs: arguments["skip_source_ids"] as? [String] ?? []
                )
            case "get_due_cards":
                return try await store.getDueCards(
                    notebookID: arguments["notebook_id"] as? String,
                    limit: try MCPDataStore.intArgument(arguments, "limit")
                )
            case "record_card_result":
                return try await store.recordCardResult(
                    cardID: arguments["card_id"] as? String,
                    itemID: arguments["item_id"] as? String,
                    remembered: arguments["remembered"],
                    asked: arguments["asked"] as? String,
                    sittingID: arguments["sitting_id"] as? String,
                    practice: arguments["practice"]
                )
            case "practice_cards":
                return try await store.practiceCards(
                    cardIDs: arguments["card_ids"],
                    title: arguments["title"] as? String
                )
            case "update_card":
                return try await store.updateCard(
                    cardID: arguments["card_id"] as? String,
                    itemID: arguments["item_id"] as? String,
                    front: arguments["front"] as? String,
                    back: arguments["back"] as? String,
                    why: arguments["why"],
                    frontImages: arguments["front_images"],
                    backImages: arguments["back_images"],
                    startOver: arguments["start_over"],
                    alwaysAsk: arguments["always_ask"],
                    retire: arguments["retire"]
                )
            case "list_practices":
                return try store.listPractices(status: arguments["status"] as? String)
            case "decide_practice":
                return try await store.decidePractice(
                    practiceID: arguments["practice_id"] as? String,
                    decision: arguments["decision"] as? String
                )
            case "set_practice":
                return try store.setPractice(
                    practiceID: arguments["practice_id"] as? String,
                    title: arguments["title"] as? String,
                    why: arguments["why"] as? String,
                    rule: arguments["rule"],
                    status: arguments["status"] as? String,
                    scope: arguments["scope"] as? String,
                    suggested: arguments["suggested"] as? Bool ?? false
                )
            case "set_review_depth":
                return try store.setReviewDepth(
                    sourceID: arguments["source_id"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    depth: arguments["depth"] as? String ?? ""
                )
            case "record_understanding":
                return try await store.recordUnderstanding(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    sessionSummary: arguments["session_summary"] as? String ?? "",
                    updates: arguments["updates"] as? [[String: Any]] ?? []
                )
            case "review_suggested_sources":
                return try store.reviewSuggestedSources(
                    goalID: arguments["goal_id"] as? String ?? "",
                    approve: arguments["approve"] as? [String] ?? [],
                    reject: arguments["reject"] as? [String] ?? []
                )
            case "add_companion_sources":
                return try await store.addCompanionSeedSources(
                    goalID: arguments["goal_id"] as? String ?? "",
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "search_sources_semantic":
                return try await store.searchSourcesSemantic(
                    queryText: arguments["query"] as? String ?? "",
                    limit: arguments["limit"] as? Int ?? 8,
                    threshold: Float(arguments["threshold"] as? Double ?? Double(EmbeddingSettings.similarityThreshold)),
                    sourceType: arguments["source_type"] as? String,
                    addedFrom: Self.searchAddedWindow(arguments).from,
                    addedTo: Self.searchAddedWindow(arguments).to,
                    notebookID: arguments["notebook_id"] as? String,
                    excludeNotebookID: arguments["exclude_notebook_id"] as? String,
                    show: arguments["show"] as? String
                )
            case "search_sources_keyword":
                return try store.searchSourcesKeyword(
                    keywords: arguments["keywords"] as? [String] ?? [],
                    matchAll: (arguments["match"] as? String)?.lowercased() == "all",
                    limit: arguments["limit"] as? Int ?? 50,
                    snippetsPerSource: arguments["snippets_per_source"] as? Int ?? 2,
                    sourceType: arguments["source_type"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    show: arguments["show"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "list_shows":
                return try store.listShows(kind: arguments["kind"] as? String)
            case "filter_sources":
                return try store.filterSources(
                    show: arguments["show"] as? String,
                    author: arguments["author"] as? String,
                    titleContains: arguments["title_contains"] as? String,
                    text: arguments["text"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    includeArchived: arguments["include_archived"] as? Bool ?? false,
                    limit: arguments["limit"] as? Int ?? 200
                )
            case "start_review_session":
                return try await store.startScopedReviewSession(
                    topic: arguments["topic"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    notebookID: arguments["notebook_id"] as? String,
                    operationID: arguments["operation_id"] as? String,
                    hostSessionID: hostSessionID
                )
            case "end_review_session":
                guard let overallScore = ToolArgumentNumber.value(arguments["overall_score"]),
                      overallScore.isFinite,
                      (0.0...1.0).contains(overallScore) else {
                    throw MCPError.invalidInput(
                        "overall_score must be a finite number from 0.0 to 1.0."
                    )
                }
                return try store.endReviewSession(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    hostSessionID: hostSessionID,
                    overallScore: overallScore,
                    summary: arguments["summary"] as? String ?? "",
                    transcript: arguments["transcript"] as? String ?? arguments["chat_export"] as? String,
                    gaps: arguments["gaps"] as? [[String: Any]] ?? [],
                    memoryAttempts: arguments["memory_attempts"] as? [[String: Any]] ?? [],
                    sourceIDs: arguments["source_ids"] as? [String] ?? [],
                    topic: arguments["topic"] as? String
                )
            case "get_review_sessions": return try store.getReviewSessions(topic: arguments["topic"] as? String, sourceId: arguments["source_id"] as? String)
            case "get_review_session_transcript":
                return try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]))
            case "import_review_chat":
                return try store.importReviewChat(
                    title: arguments["title"] as? String ?? "",
                    transcript: arguments["transcript"] as? String ?? arguments["chat_export"] as? String ?? "",
                    transcriptFile: arguments["transcript_file"] as? String,
                    sourceIDs: arguments["source_ids"] as? [String],
                    summary: arguments["summary"] as? String,
                    overallScore: clampUnitInterval(optional: arguments["overall_score"] as? Double),
                    modelProvider: arguments["model_provider"] as? String,
                    modelID: arguments["model_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    sessionID: (arguments["session_id"] as? String).map { MCPDataStore.reviewSessionID(from: $0) },
                    startedAt: (arguments["started_at"] as? String).flatMap(MCPDataStore.parseISODate),
                    endedAt: (arguments["ended_at"] as? String).flatMap(MCPDataStore.parseISODate),
                    marksReviewed: arguments["mark_reviewed"] as? Bool
                )
            case "search_review_sessions":
                return try store.searchReviewSessions(
                    queryText: arguments["query"] as? String ?? "",
                    limit: arguments["limit"] as? Int ?? 10
                )
            case "list_review_session_links": return try store.listReviewSessionLinks()
            case "add_source":
                if let refusal = Self.ingestNotebookRefusal(arguments, access: access) { return refusal }
                return try await store.addSourceNamingVideoChannel(
                    url: arguments["url"] as? String ?? "",
                    title: arguments["title"] as? String ?? "",
                    sourceType: arguments["source_type"] as? String ?? "article",
                    content: arguments["content"] as? String,
                    parentGroup: arguments["parent_group"] as? String,
                    author: arguments["author"] as? String,
                    occurredAt: arguments["occurred_at"] as? String,
                    // Provenance comes from the authenticated OAuth client, never
                    // from arguments; full-scope assistants keep .manual.
                    connectorLabel: access.scope == .ingest ? access.connectorLabel : nil,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "add_sources":
                if let refusal = Self.ingestNotebookRefusal(arguments, access: access) { return refusal }
                return try await store.addSourcesFilingInNotebook(
                    arguments["sources"] as? [[String: Any]] ?? [],
                    connectorLabel: access.scope == .ingest ? access.connectorLabel : nil,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "update_source_content":
                return try store.updateSourceContent(
                    sourceID: arguments["source_id"] as? String,
                    url: arguments["url"] as? String,
                    content: arguments["content"] as? String,
                    title: arguments["title"] as? String,
                    author: arguments["author"] as? String,
                    restrictToPluginLabel: access.scope == .ingest ? access.connectorLabel : nil
                )
            case "remove_connector_sources":
                return try store.removePluginSources(label: arguments["connector_label"] as? String ?? "")
            case "import_paper_from_url":
                return try await store.importPaperFilingInNotebook(
                    url: arguments["url"] as? String ?? "",
                    sourceURL: arguments["source_url"] as? String,
                    title: arguments["title"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                )
            case "import_connector_paper":
                guard access.scope == .ingest else {
                    return "Error: import_connector_paper is only available to an ingest-only plugin."
                }
                return try await store.importPluginPaper(
                    url: arguments["url"] as? String,
                    filePath: arguments["file_path"] as? String,
                    sourceURL: arguments["source_url"] as? String,
                    title: arguments["title"] as? String,
                    connectorLabel: access.connectorLabel
                )
            case "delete_source":
                return try await store.deleteSourceWithItsAudio(arguments["source_id"] as? String ?? "")
            case "remove_source":
                return try store.removeSource(arguments["source_id"] as? String ?? "")
            case "archive_source":
                return try store.archiveSource(arguments["source_id"] as? String ?? "")
            case "unarchive_source":
                return try store.unarchiveSourceRestoringContent(arguments["source_id"] as? String ?? "")
            case "set_source_hidden":
                return try store.setSourceHidden(
                    sourceID: arguments["source_id"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_source_paywall_status":
                return try store.setSourcePaywallStatus(
                    sourceID: arguments["source_id"] as? String ?? "",
                    isPaywalled: arguments["is_paywalled"] as? Bool ?? true
                )
            case "set_podcast_episode_hidden":
                return try store.setPodcastEpisodeHidden(
                    sourceID: arguments["source_id"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_podcast_show_hidden":
                return try store.setPodcastShowHidden(
                    showName: arguments["show_name"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_podcast_show_import_blocked":
                return try store.setPodcastShowImportBlocked(
                    showName: arguments["show_name"] as? String ?? "",
                    blocked: arguments["blocked"] as? Bool ?? true
                )
            case "set_podcast_episode_visible_override":
                return try store.setPodcastEpisodeVisibleOverride(
                    sourceID: arguments["source_id"] as? String ?? "",
                    visible: arguments["visible"] as? Bool ?? true
                )
            case "set_youtube_channel_hidden":
                return try store.setYouTubeChannelHidden(
                    channelName: arguments["channel_name"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "set_youtube_video_visible_override":
                return try store.setYouTubeVideoVisibleOverride(
                    sourceID: arguments["source_id"] as? String ?? "",
                    visible: arguments["visible"] as? Bool ?? true
                )
            case "attach_text_file_to_source":
                return try store.attachTextFileToSource(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String ?? ""
                )
            case "attach_supplementary_pdf":
                return try await store.attachSupplementaryPDF(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String,
                    pdfURL: arguments["pdf_url"] as? String
                )
            case "attach_pdf_to_paper":
                return try await store.attachPDFToPaper(
                    sourceID: arguments["source_id"] as? String ?? "",
                    filePath: arguments["file_path"] as? String,
                    pdfURL: arguments["pdf_url"] as? String
                )
            case "download_papers_needing_attention":
                return try await store.downloadPapersNeedingAttention(
                    sourceIDs: arguments["source_ids"] as? [String],
                    limit: arguments["limit"] as? Int
                )
            case "recheck_paywalled_papers":
                return try await store.recheckPaywalledPapers(
                    sourceIDs: arguments["source_ids"] as? [String],
                    limit: arguments["limit"] as? Int
                )
            case "rename_group":
                return try store.renameGroup(
                    groupType: arguments["group_type"] as? String ?? "",
                    groupKey: arguments["group_key"] as? String ?? "",
                    newTitle: arguments["new_title"] as? String ?? ""
                )
            case "set_group_hidden":
                return try store.setGroupHidden(
                    groupType: arguments["group_type"] as? String ?? "",
                    groupKey: arguments["group_key"] as? String ?? "",
                    hidden: arguments["hidden"] as? Bool ?? true
                )
            case "get_source_settings":
                return try store.getSourceSettings()
            case "list_unconverted_zoom_recordings":
                return try await store.listUnconvertedZoomRecordings()
            case "resolve_unconverted_zoom_recording":
                return try await store.resolveUnconvertedZoomRecording(
                    folderPath: arguments["folder_path"] as? String ?? "",
                    action: arguments["action"] as? String ?? ""
                )
            case "get_day_settings":
                return try await store.getDaySettings()
            case "set_day_settings":
                return try await store.setDaySettings(
                    dayStartHour: try MCPDataStore.intArgument(arguments, "day_start_hour"),
                    dayEndHour: try MCPDataStore.intArgument(arguments, "day_end_hour"),
                    suggestPlanningTheDay: arguments["suggest_planning_the_day"] as? Bool,
                    forcePlanningTheDay: arguments["force_planning_the_day"] as? Bool,
                    requestNotifications: arguments["request_notifications"] as? Bool,
                    nudgeBackOnTrack: arguments["nudge_back_on_track"] as? Bool,
                    readScreen: arguments["read_screen"] as? Bool
                )
            case "get_own_router_key":
                return try store.getOwnRouterKey()
            case "set_own_router_key":
                return try store.setOwnRouterKey(
                    router: arguments["router"] as? String ?? "",
                    key: arguments["key"] as? String,
                    clear: arguments["clear"] as? Bool ?? false
                )
            case "get_ai_usage_report":
                return try store.getAIUsageReport(
                    days: (arguments["days"] as? NSNumber)?.intValue,
                    from: arguments["from"] as? String,
                    to: arguments["to"] as? String
                )
            case "get_ai_task_settings":
                return try await store.getAITaskSettings()
            case "set_ai_task_settings":
                return try await store.setAITaskSettings(
                    target: arguments["target"] as? String ?? "",
                    provider: arguments["provider"] as? String,
                    model: arguments["model"] as? String,
                    hideTrainingModels: arguments["hide_training_models"] as? Bool,
                    meetingsMayUseFree: arguments["meetings_may_use_free"] as? Bool,
                    hostFor: arguments["host_for"] as? String,
                    host: arguments["host"] as? String,
                    hostFallback: arguments["host_fallback"] as? Bool,
                    hostRegion: arguments["host_region"] as? String,
                    backupsFor: arguments["backups_for"] as? String,
                    backups: arguments["backups"] as? [[String: Any]],
                    taskID: arguments["task_id"] as? String,
                    retiredArguments: MCPDataStore.retiredAITaskSettingsArguments.filter { arguments[$0] != nil }
                )
            case "set_source_settings":
                return try await store.setSourceSettings(
                    family: arguments["family"] as? String ?? "",
                    includeInSearchAndAI: arguments["include_in_search_and_ai"] as? Bool,
                    pinned: arguments["pinned"] as? Bool
                )
            case "set_connector_auto_import":
                return try store.setPluginAutoImport(
                    plugin: arguments["connector"] as? String ?? "",
                    enabled: arguments["enabled"] as? Bool ?? false
                )
            case "follow_youtube_liked_videos":
                return try await store.followYouTubeLikedVideosMCP(
                    account: arguments["account"] as? String,
                    importExisting: arguments["import_existing"] as? Bool ?? true,
                    automaticallyFormatTranscripts:
                        arguments["format_transcripts_automatically"] as? Bool ?? false
                )
            case "follow_youtube_foreverlm_playlist":
                return try await store.followYouTubeForeverLMPlaylistMCP(account: arguments["account"] as? String)
            case "refresh_youtube_sources":
                return try await store.refreshYouTubeSourcesMCP(account: arguments["account"] as? String)
            case "import_youtube_playlist":
                return try await store.importYouTubePlaylistMCP(
                    url: arguments["url"] as? String ?? "",
                    courseID: arguments["course_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "import_teachable_course":
                return try await store.importTeachableCourseMCP(
                    url: arguments["url"] as? String ?? "",
                    courseID: arguments["course_id"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "import_gemini_notebook":
                return try await store.importGeminiNotebookMCP(
                    url: arguments["url"] as? String ?? "",
                    notebookID: arguments["notebook_id"] as? String
                )
            case "import_video_overview":
                return try await store.importVideoOverviewMCP(
                    filePath: arguments["file_path"] as? String ?? "",
                    notebookID: arguments["notebook_id"] as? String
                )
            case "create_course":
                return try store.createCourse(
                    title: arguments["title"] as? String ?? "",
                    courseCode: arguments["course_code"] as? String,
                    institution: arguments["institution"] as? String,
                    instructors: arguments["instructors"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "generate_course":
                return try await store.generateCourse(
                    topic: arguments["topic"] as? String ?? "",
                    learnerNotes: arguments["learner_notes"] as? String,
                    useWeb: arguments["use_web"] as? Bool ?? false,
                    moduleCount: arguments["module_count"] as? Int,
                    scheduleStart: arguments["schedule_start"] as? String,
                    daysPerModule: arguments["days_per_module"] as? Int,
                    writeQuizzes: arguments["quizzes"] as? Bool ?? false,
                    chosenSourceIDs: arguments["source_ids"] as? [String] ?? [],
                    agreedPlan: arguments["plan"] as? String,
                    notebookID: arguments["notebook_id"] as? String
                )
            case "generate_course_quizzes":
                return try await store.generateCourseQuizzes(arguments: arguments)
            case "add_course_quiz_pictures":
                return try await store.addCourseQuizPictures(arguments: arguments)
            case "get_course_quiz":
                return try store.getCourseQuiz(arguments: arguments)
            case "save_course_quiz":
                return try store.saveCourseQuiz(arguments: arguments)
            case "delete_course_quiz":
                return try store.deleteCourseQuiz(arguments: arguments)
            case "rename_course_quiz":
                return try store.renameCourseQuiz(arguments: arguments)
            case "set_course_quiz_picture":
                return try store.setCourseQuizPicture(arguments: arguments)
            case "record_course_quiz_result":
                return try await store.recordCourseQuizResult(arguments: arguments)
            case "save_course_textbook_readings":
                return try await store.saveCourseTextbookReadings(arguments: arguments)
            case "add_textbook_to_course":
                return try await store.addTextbookToCourse(arguments: arguments)
            case "generate_explainer":
                return try await store.generateExplainer(
                    sourceID: arguments["source_id"] as? String ?? "",
                    lengthName: arguments["length"] as? String,
                    generateAudio: arguments["generate_audio"] as? Bool ?? true,
                    confirmCost: arguments["confirm_cost"] as? Bool ?? false,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                        ?? MCPRunningWork.defaultSpendLimitUSD
                )
            case "generate_audio_overview":
                return try await store.generateAudioOverview(arguments: arguments)
            case "generate_report":
                return try await store.generateReport(arguments: arguments)
            case "generate_explainer_video":
                return try await store.generateExplainerVideo(arguments: arguments)
            case "generate_walkthrough":
                return try await store.generateWalkthrough(arguments: arguments)
            case "get_walkthrough":
                return try await store.getWalkthrough(arguments: arguments)
            case "list_walkthroughs":
                return try await store.listWalkthroughs(notebookID: arguments["notebook_id"] as? String)
            case "save_walkthrough":
                return try await store.saveWalkthrough(arguments: arguments)
            case "delete_walkthrough":
                return try await store.deleteWalkthrough(arguments: arguments)
            case "update_course":
                return try store.updateCourse(
                    courseID: arguments["course_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    courseCode: arguments["course_code"] as? String,
                    institution: arguments["institution"] as? String,
                    instructors: arguments["instructors"] as? String,
                    playlistURL: arguments["playlist_url"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    unlinkNotebookID: arguments["unlink_notebook_id"] as? String
                )
            case "delete_course":
                return try store.deleteCourse(courseID: arguments["course_id"] as? String ?? "")
            case "create_course_lecture":
                return try store.createCourseLectureResolved(
                    courseIdentifier: arguments["course_id"] as? String
                        ?? arguments["course_name"] as? String
                        ?? "",
                    identifierIsStableID: arguments["course_id"] as? String != nil,
                    title: arguments["title"] as? String,
                    number: arguments["number"] as? Int
                )
            case "rename_course_lecture":
                return try store.renameCourseLecture(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    title: arguments["title"] as? String ?? ""
                )
            case "add_source_to_lecture":
                return try store.addSourceToLecture(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String ?? "",
                    role: arguments["role"] as? String
                )
            case "add_paper_to_lecture":
                return try store.addPaperToLecture(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    sourceID: arguments["source_id"] as? String ?? "",
                    assignedReading: arguments["assigned_reading"] as? Bool
                )
            case "find_lecture_papers":
                return try await store.findLecturePapers(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false
                )
            case "ingest_lecture_papers":
                return try await store.ingestLecturePapers(
                    lectureID: arguments["lecture_id"] as? String ?? "",
                    citedPaperIDs: arguments["cited_paper_ids"] as? [String] ?? [],
                    assignedReadingIDs: arguments["assigned_reading_ids"] as? [String] ?? []
                )
            case "remove_course_lecture_item":
                return try store.removeCourseLectureItem(itemID: arguments["item_id"] as? String ?? "")
            case "move_source_type":
                return try store.moveSourceType(
                    sourceID: arguments["source_id"] as? String ?? "",
                    newType: arguments["new_type"] as? String ?? ""
                )
            case "remove_all_from_podcast":
                return try store.removeAllFromPodcastShow(showName: arguments["show_name"] as? String ?? "")
            case "delete_review_session":
                return try store.deleteReviewSession(sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]))
            case "update_review_session_sources":
                return try store.updateReviewSessionLinkedSources(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    sourceIDs: arguments["source_ids"] as? [String] ?? []
                )
            case "update_review_session":
                return try store.updateReviewSession(
                    sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                    title: arguments["title"] as? String,
                    notebookID: arguments["notebook_id"] as? String,
                    isHidden: arguments["is_hidden"] as? Bool,
                    isPinned: arguments["is_pinned"] as? Bool
                )
            case "extract_paper_metadata":
                return try await store.extractPaperMetadataForSource(sourceID: arguments["source_id"] as? String ?? "")
            case "extract_article_metadata":
                return try await store.extractArticleMetadataForSource(sourceID: arguments["source_id"] as? String ?? "")
            case "find_duplicate_papers":
                return try await store.findDuplicatePapers(archiveDuplicates: arguments["archive_duplicates"] as? Bool ?? false)
            case "find_podcast_match":
                return try await store.findPodcastMatch(sourceID: arguments["source_id"] as? String ?? "")
            case "resolve_podcast_match":
                return try await store.resolvePodcastMatch(
                    sourceID: arguments["source_id"] as? String ?? "",
                    confirm: arguments["confirm"] as? Bool ?? false
                )
            case "find_podcast_on_youtube":
                return try await store.findPodcastOnYouTube(
                    sourceID: arguments["source_id"] as? String ?? "",
                    alwaysForShow: arguments["always_for_show"] as? Bool
                )
            case "import_podcast_youtube_transcript":
                return try await store.importPodcastYouTubeTranscript(
                    sourceID: arguments["source_id"] as? String ?? "",
                    video: arguments["video"] as? String ?? "",
                    replace: arguments["replace"] as? Bool ?? false
                )
            case "refetch_source_content":
                return try await store.refetchSourceContent(sourceID: arguments["source_id"] as? String ?? "")
            case "import_local_pdf_as_paper":
                return try await store.importLocalPDFAsPaperInBackground(
                    filePath: arguments["file_path"] as? String ?? "",
                    title: arguments["title"] as? String,
                    tool: "import_local_pdf_as_paper",
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                )
            case "import_local_file":
                return try await store.importLocalFile(
                    filePath: arguments["file_path"] as? String ?? "",
                    kind: arguments["kind"] as? String,
                    title: arguments["title"] as? String,
                    approvedSpendUSD: (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
                )
            case "fetch_video_transcript":
                return try await store.fetchVideoTranscript(
                    sourceID: arguments["source_id"] as? String ?? "",
                    passcode: arguments["passcode"] as? String
                )
            case "list_video_cited_papers":
                return try store.listVideoCitedPapers(sourceID: arguments["source_id"] as? String ?? "")
            case "import_video_cited_paper":
                return try await store.importVideoCitedPaper(
                    citedPaperID: arguments["cited_paper_id"] as? String ?? ""
                )
            case "update_video_cited_paper_status":
                return try store.updateVideoCitedPaperStatus(
                    citedPaperID: arguments["cited_paper_id"] as? String ?? "",
                    status: arguments["status"] as? String ?? ""
                )
            case "extract_video_slides":
                return try await store.extractVideoSlides(sourceID: arguments["source_id"] as? String ?? "")
            case "scan_video_for_cited_papers":
                return try await store.scanVideoForCitedPapers(
                    sourceID: arguments["source_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false,
                    exhaustive: arguments["all_slides"] as? Bool ?? false
                )
            case "scan_meeting_for_mentioned_papers":
                return try await store.scanMeetingForMentionedPapers(
                    sourceID: arguments["source_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false
                )
            case "make_article_reading_view":
                return try await store.makeArticleReadingView(
                    sourceID: arguments["source_id"] as? String ?? "",
                    instruction: arguments["instruction"] as? String ?? ""
                )
            case "get_article_reading_view":
                return try store.getArticleReadingView(sourceID: arguments["source_id"] as? String ?? "")
            case "set_article_reading_view_shown":
                return try store.setArticleReadingViewShown(
                    sourceID: arguments["source_id"] as? String ?? "",
                    shown: arguments["shown"] as? Bool ?? true
                )
            case "clear_article_reading_view":
                return try store.clearArticleReadingView(sourceID: arguments["source_id"] as? String ?? "")
            case "scan_article_for_linked_sources":
                return try await store.scanArticleForLinkedSources(
                    sourceID: arguments["source_id"] as? String ?? "",
                    force: arguments["force"] as? Bool ?? false
                )
            case "fetch_source_from_archive":
                return try await store.fetchSourceFromArchive(sourceID: arguments["source_id"] as? String ?? "")
            case "clear_source_derived_data":
                return try store.clearSourceDerivedData(arguments["source_id"] as? String ?? "")
            case "set_source_read":
                return try store.setSourceRead(
                    sourceID: arguments["source_id"] as? String ?? "",
                    read: arguments["read"] as? Bool ?? true
                )
            case "update_source":
                return try store.updateSource(
                    sourceID: arguments["source_id"] as? String ?? "",
                    title: arguments["title"] as? String,
                    author: arguments["author"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    journal: arguments["journal"] as? String,
                    publishedYear: arguments["published_year"] as? String,
                    doi: arguments["doi"] as? String,
                    isPaywalled: arguments["is_paywalled"] as? Bool,
                    parentGroup: arguments["parent_group"] as? String,
                    content: arguments["content"] as? String
                )
            default:
                return "Unknown tool: \(name)"
            }
        } catch {
            logger.error("Tool \(name) failed: \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Data Store (Direct SQLite + JSON access)

/// Reads/writes knowledge.db and source files directly.
final class MCPDataStore {
    let logger = Logger(subsystem: "ForeverLM", category: "MCPDataStore")
    typealias SourceEmbeddingProvider = @Sendable (String) async throws -> [Float]

    /// Apple epoch offset (2001-01-01 vs 1970-01-01)
    let appleEpochOffset: TimeInterval = 978307200

    /// Optional override for testing — when set, all DB operations use this path instead of iCloud.
    let dbPathOverride: String?
    let sourceEmbeddingProvider: SourceEmbeddingProvider?
    /// The writer `generate_explainer` runs when its caller hands in none; nil
    /// is the live model route. Tests hand in one that answers when told to.
    let explainerBackend: ExplainerModelBackend?
    /// Where the card tools read and write the `cards.state.<deckID>` rows:
    /// the standard defaults, which sync; a test hands in a suite of its own.
    let cardStateDefaults: UserDefaults

    /// One long-lived KnowledgeStore, reused across tool calls. Opening a fresh
    /// KnowledgeStore per call re-ran `createSchema` (DDL) and left connections with
    /// no busy_timeout, so concurrent MCP calls could churn connections and hit
    /// "database is locked". Guarded by `storeLock` because tool calls run on
    /// concurrent per-request Tasks.
    private let storeLock = NSLock()
    private var cachedStore: KnowledgeStore?
    let notebookFileStorage: StorageService
    private let operationGate = MCPKnowledgeStoreOperationGate()
    /// Built on first use and shared by every picture tool call, so a figure
    /// two calls ask about at once is indexed and explained once. Guarded by
    /// `storeLock` for the same reason `cachedStore` is.
    private var cachedPaperFigureIndexer: PaperFigureIndexer?
    var paperFigureIndexer: PaperFigureIndexer {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let cachedPaperFigureIndexer { return cachedPaperFigureIndexer }
        let indexer = PaperFigureIndexer(storage: notebookFileStorage, aiService: AIService())
        cachedPaperFigureIndexer = indexer
        return indexer
    }

    // Tuning for Learning Companion source discovery (used by MCPTools+Companion.swift;
    // stored properties must live in the primary class declaration).
    //
    // The library's own hybrid search (`SourceSearchEngine`) lists the candidates and a
    // model keeps the ones that fit. No similarity gate can do the keeping: the
    // contextual embedding is anisotropic, so a topic's twelve nearest chunks scored
    // 0.922–0.929 whether they came from a paper on the topic or one on psychedelics and
    // terahertz waves (product owner, 2026-10-11: "it finds weird sources that are barely
    // related").
    let companionDiscoveryPool = 24
    /// Most of a goal's own sources that steer its discovery (`companionDiscoverySeeds`).
    let companionDiscoverySeedLimit = 6
    let companionDiscoveryLimit = 12
    /// Which of a discovery pass's candidates fit the Notebook or Goal, by
    /// candidate id. Nil is the live model (`liveLibraryFitJudge`); a test
    /// hands in its own verdict.
    typealias LibraryFitJudge = @Sendable (JournalMatchingNotebook, [JournalMatchingCandidate]) async throws -> Set<String>
    let libraryFitJudge: LibraryFitJudge?

    init(
        dbPath: String? = nil,
        sourceEmbeddingProvider: SourceEmbeddingProvider? = nil,
        explainerBackend: ExplainerModelBackend? = nil,
        libraryFitJudge: LibraryFitJudge? = nil,
        cardStateDefaults: UserDefaults = .standard
    ) {
        self.dbPathOverride = dbPath
        self.sourceEmbeddingProvider = sourceEmbeddingProvider
        self.explainerBackend = explainerBackend
        self.libraryFitJudge = libraryFitJudge
        self.cardStateDefaults = cardStateDefaults
        if let dbPath {
            self.notebookFileStorage = StorageService(storeRoot: URL(fileURLWithPath: dbPath).deletingLastPathComponent())
        } else {
            self.notebookFileStorage = StorageService()
        }
    }

    /// ForeverLM's iCloud Documents folder, read by plain path
    /// (`ForeverLMRuntimeIdentity.iCloudDocumentsFolderName`).
    var icloudContainer: URL {
        let home: URL
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = URL(fileURLWithPath: NSHomeDirectory())
        }
        return home
            .appendingPathComponent("Library/Mobile Documents/\(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName)")
    }

    var libraryDir: URL {
        icloudContainer.appendingPathComponent(
            "Documents/\(ForeverLMRuntimeIdentity.productFolderName)"
        )
    }

    var localAppDataDir: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent(".appdata", isDirectory: true)
    }

    var knowledgeDBPath: String { dbPathOverride ?? localAppDataDir.appendingPathComponent("knowledge.db").path }

    var sourceContentRoot: URL {
        if dbPathOverride != nil {
            return URL(fileURLWithPath: knowledgeDBPath).deletingLastPathComponent()
        }
        return libraryDir
    }

    /// Relativize a path under `sourceContentRoot`. In production the content root
    /// is the ForeverLM root, so this matches `StorageService.relativeSourcePath`;
    /// with an overridden DB path (tests) the content root lives elsewhere and
    /// `relativeSourcePath` would return the absolute path unchanged.
    func relativeSourceContentPath(_ url: URL) -> String? {
        let root = sourceContentRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    func knowledgeStore() throws -> KnowledgeStore {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let cachedStore {
            return cachedStore
        }
        let store = try KnowledgeStore(storeDirectory: URL(fileURLWithPath: knowledgeDBPath).deletingLastPathComponent())
        cachedStore = store
        return store
    }

    /// Every MCP tool acquires this before execution and releases it only after the
    /// whole tool returns. Keep the gate here beside ownership of the shared
    /// connection so future dispatch surfaces cannot accidentally grow a second,
    /// uncoordinated lock. The default is the exclusive hold, which is always
    /// safe; `MCPToolRegistry.storeGateMode(for:)` decides when a tool may share.
    func acquireToolOperation(_ mode: MCPStoreOperationMode = .exclusive) async {
        await operationGate.acquire(mode)
    }

    func releaseToolOperation() async {
        await operationGate.release()
    }

    /// Runs `body` holding the store gate. A tool in
    /// `MCPToolRegistry.selfGatedToolNames` wraps each stretch that touches the
    /// cached connection in this, and nothing else, so its model calls and
    /// downloads between the stretches hold nothing. Inside a hold that
    /// already covers `mode` (the dispatcher's for a gated tool, or an
    /// enclosing stretch) the body runs under that hold. A write asked for
    /// inside a shared hold is refused: the reader would wait on itself.
    func withStoreGate<T>(
        _ mode: MCPStoreOperationMode,
        _ body: () async throws -> T
    ) async throws -> T {
        if let held = MCPStoreGateHold.current, held.isHeld {
            guard held.mode == .exclusive || mode == .shared else {
                throw MCPError.database("A write to the library was attempted inside a call that holds it only to read.")
            }
            return try await body()
        }
        await operationGate.acquire(mode)
        let hold = MCPStoreGateHold(mode)
        do {
            let value = try await MCPStoreGateHold.$current.withValue(hold, operation: body)
            hold.end()
            await operationGate.release()
            return value
        } catch {
            hold.end()
            await operationGate.release()
            throw error
        }
    }

    /// Saves what a call learned about a source during a long wait (streaming
    /// a video's frames, a transcription, a model reading its slides), holding
    /// the store gate alone for the write only. The row is read again inside
    /// the gate and `change` edits that copy, so a field another call saved
    /// during the wait is kept rather than overwritten by the copy read before
    /// it, and a source deleted meanwhile is not written back. `change`
    /// answers false when the fresh copy needs nothing saved.
    @discardableResult
    func saveSourceAfterWait(
        _ sourceID: String,
        _ change: (inout StudioArticle) throws -> Bool
    ) async throws -> StudioArticle {
        try await withStoreGate(.exclusive) {
            let store = try knowledgeStore()
            guard var article = try store.loadSourceForSync(sourceID) else {
                throw MCPError.notFound("Source \(sourceID) was deleted while this call ran, so nothing was saved to it.")
            }
            if try change(&article) {
                try store.saveSource(article)
            }
            return article
        }
    }

    // MARK: - Client-Supplied Path Validation

    /// Largest file an MCP client may hand to an attach/import tool. Reads load the
    /// whole file into memory, so this bounds a single tool call's footprint.
    static let maxClientProvidedFileBytes = 100 * 1024 * 1024

    /// Most .json files one import_meeting_transcript_files call will process.
    static let maxClientProvidedFolderFiles = 500

    /// Roots an MCP client is allowed to read from, fully symlink-resolved so they
    /// compare cleanly against resolved candidate paths: the ForeverLM content root
    /// (plus the test-override content root when set), the app-data dir, the temp
    /// dir (internal tools stage files there), and the user's standard content
    /// folders where files to import naturally live.
    func allowedClientPathRoots() -> [String] {
        var roots: [URL] = [
            sourceContentRoot,
            libraryDir,
            localAppDataDir,
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        ]
        let home = Self.userHomeDirectory()
        for folder in ["Desktop", "Documents", "Downloads"] {
            roots.append(home.appendingPathComponent(folder, isDirectory: true))
        }
        return roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    /// The account's real home, not a sandbox container's.
    static func userHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Where Claude Code keeps its session files: one directory per working
    /// directory, one `<session id>.jsonl` per session. Read by
    /// `import_review_chat`'s `transcript_file` and by nothing else.
    lazy var claudeCodeProjectsRoot: URL = Self.userHomeDirectory().appendingPathComponent(".claude/projects", isDirectory: true)

    /// Vet a path supplied by an MCP client before reading it.
    ///
    /// `attach_*` / import tools would otherwise read any path the caller names, so
    /// an external assistant could exfiltrate SSH keys, keychains, or system config —
    /// especially in the unsandboxed direct-download build. Only paths inside
    /// `allowedClientPathRoots()` are accepted, symlinks are resolved BEFORE the
    /// check so a link inside an allowed folder can't smuggle a read from elsewhere,
    /// known credential locations are refused outright as defense in depth, and
    /// oversized files are rejected. Returns the fully resolved URL — callers must
    /// perform the actual read through it, never through the raw input.
    @discardableResult
    /// An integer argument as JSON delivers it — an Int, or a Double when the
    /// number was written with a fraction or an exponent. A value Int cannot
    /// hold is refused: until 2026-09-19 `Int(1e30)` trapped in the handler and
    /// one authenticated request took the app, and its tunnel, down.
    static func intArgument(_ arguments: [String: Any], _ key: String) throws -> Int? {
        try intValue(arguments[key], key)
    }

    /// The one way an MCP argument value becomes an `Int`. JSON numbers arrive
    /// as `Double`, and `Int(double)` traps on NaN, infinity or a value `Int`
    /// cannot hold: `1e30` once took the app and its tunnel down (2026-09-19).
    /// Every tool's integer read, nested values included, comes through here.
    static func intValue(_ value: Any?, _ key: String) throws -> Int? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double {
            guard double.isFinite, let exact = Int(exactly: double.rounded(.towardZero)),
                  double.magnitude < 9_007_199_254_740_992 else {
                throw MCPError.invalidInput("\(key) must be a whole number Int can hold; got \(double).")
            }
            return exact
        }
        if let text = value as? String, let int = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return int }
        throw MCPError.invalidInput("\(key) must be a whole number.")
    }

    func validateClientProvidedPath(_ rawPath: String, additionalRoots: [String] = []) throws -> URL {
        var candidate = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw MCPError.invalidInput("file_path is required.")
        }
        if candidate.hasPrefix("file://") { candidate = String(candidate.dropFirst(7)) }
        if candidate.hasPrefix("~") { candidate = (candidate as NSString).expandingTildeInPath }

        // Reject traversal both in the raw input and after normalization.
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL
        if candidate.contains("../") || candidate.hasSuffix("/..") || candidate == ".."
            || standardized.pathComponents.contains("..") {
            throw MCPError.invalidInput("Refusing path with parent-directory traversal: \(rawPath)")
        }

        // Resolve symlinks so allowlist and denylist checks see the real target.
        let resolved = standardized.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        let roots = allowedClientPathRoots() + additionalRoots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard roots.contains(where: { resolvedPath == $0 || resolvedPath.hasPrefix($0 + "/") }) else {
            let extra = additionalRoots.isEmpty ? "" : ", or \(additionalRoots.joined(separator: ", "))"
            throw MCPError.invalidInput("file_path must point inside the ForeverLM library or your Desktop, Documents, or Downloads folder\(extra): \(rawPath)")
        }

        // Defense in depth: never serve known credential locations, even if a
        // future root change or a mount under an allowed folder exposes one.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let sensitivePrefixes = [
            "/etc", "/private/etc", "/var/db", "/var/root", "/System", "/Library/Keychains",
            home + "/.ssh", home + "/.aws", home + "/.gnupg", home + "/.config",
            home + "/Library/Keychains", home + "/Library/Cookies",
        ]
        for prefix in sensitivePrefixes where resolvedPath == prefix || resolvedPath.hasPrefix(prefix + "/") {
            throw MCPError.invalidInput("Refusing to read from a protected location: \(rawPath)")
        }

        if let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxClientProvidedFileBytes {
            throw MCPError.invalidInput("File is too large to import (\(size / (1024 * 1024)) MB; limit \(Self.maxClientProvidedFileBytes / (1024 * 1024)) MB): \(rawPath)")
        }
        return resolved
    }

    // MARK: - Local File Content Extraction

    /// Extract text from a local PDF or text file on disk: for a book chapter,
    /// `pages` of its book's file. Resolves relative paths against the app's
    /// Documents directory.
    static func extractTextFromLocalFile(_ path: String, pages: Range<Int>? = nil) -> String? {
        guard let resolved = SourceService.resolveLocalFileURL(path) else { return nil }
        let fullPath = resolved.path
        // A file on disk, or a chapter of an EPUB book kept as one file: its text, not its markup.
        let lower = fullPath.lowercased()
        if lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
            guard let raw = EPUBBookFiles.text(atPath: fullPath) else { return nil }
            let text = EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard FileManager.default.fileExists(atPath: fullPath) else { return nil }

        if fullPath.lowercased().hasSuffix(".pdf") {
            guard let doc = PDFDocument(url: resolved) else { return nil }
            let range = pages ?? 0..<doc.pageCount
            guard range.upperBound <= doc.pageCount else { return nil }
            let text = PDFTextExtractor.textWithFigureReferences(from: doc, pages: range)
            return text.isEmpty ? nil : text
        }

        return try? String(contentsOfFile: fullPath, encoding: .utf8)
    }

    /// The pages `book_page_start` and `book_page_count` name in a
    /// `source_projection` row read through `query`: a book chapter's pages of
    /// its book's file.
    static func bookPages(_ row: [String: Any]) -> Range<Int>? {
        guard let start = row["book_page_start"] as? Int, let count = row["book_page_count"] as? Int,
              start >= 0, count > 0 else { return nil }
        return start..<(start + count)
    }

    // MARK: - SQLite Helper

    func withDB<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(knowledgeDBPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw MCPError.database("Failed to open knowledge.db: \(msg)")
        }
        defer { sqlite3_close(db) }
        // Wait up to 5s for a competing writer instead of failing immediately with
        // "database is locked" when another connection (or CloudKit sync) holds it.
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // As on KnowledgeStore's connection, so a delete made here would cascade
        // exactly as one made there (docs/cloudkit-schema-design.md §5.7).
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        return try block(db)
    }

    func query(_ db: OpaquePointer, _ sql: String, params: [Any] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let s as String: SQLiteText.bind(stmt, idx, s)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            default: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let colCount = sqlite3_column_count(stmt)
            for c in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT: row[name] = SQLiteText.column(stmt, c)
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_NULL: break
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func execute(_ db: OpaquePointer, _ sql: String, params: [Any] = []) throws {
        _ = try query(db, sql, params: params)
    }

    func appleToISO(_ appleTimestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: appleTimestamp + appleEpochOffset)
        let fmt = ISO8601DateFormatter()
        return fmt.string(from: date)
    }

    func appleDate(_ appleTimestamp: Double) -> Date {
        Date(timeIntervalSince1970: appleTimestamp + appleEpochOffset)
    }

    func isoDateOnly(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return appleToISO(date.timeIntervalSince1970 - appleEpochOffset)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
    }

    // MARK: - Server Status

    func getMCPStatus(toolCount: Int) async throws -> String {
        var payload: [String: Any] = [
            "status": "active",
            "server": "ForeverLM MCP",
            "protocol": "MCP Streamable HTTP",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "tool_count": toolCount,
            "message": "ForeverLM MCP is active and responding to tool calls.",
        ]

        // Which iCloud account this Mac's library syncs with, so a web page
        // reading another account's library is never relayed here
        // (MCPTools+ICloudAccount.swift).
        let syncs = CloudRuntimeAvailability.isEnabled
        let userRecordName = syncs ? await CloudKitAccountIdentity.shared.currentRecordName() : nil
        payload["icloud_account"] = Self.iCloudAccountStatus(
            syncs: syncs,
            userRecordName: userRecordName,
            environment: CloudRuntimeAvailability.containerEnvironment.rawValue
        )
        // Which Mac answered: two Macs on one Apple Account share the iCloud
        // account above, and the relay serves whichever holds the tunnel
        // (MCPTools+ICloudAccount.swift).
        payload["answered_by"] = await Self.answeringMac()
        if let note = Self.screenRecordNarrowedNote { payload["narrowed"] = note }

        // Search-index coverage, so the "every source is searchable" invariant can be
        // checked rather than assumed. `pending` counts active sources whose text has
        // changed since it was indexed, or that were never indexed at all; it drains in
        // the background and should settle at 0.
        // In a shared stretch of its own (`selfGatedToolNames`), so the wait
        // on CloudKit above never holds the gate.
        if let coverage = try? await withStoreGate(.shared, {
            try knowledgeStore().indexCoverage(model: StorageService.sourceEmbeddingModel)
        }) {
            payload["search_index"] = [
                "embedding_model": StorageService.sourceEmbeddingModel,
                "active_sources": coverage.activeSources,
                "indexed_sources": coverage.indexedSources,
                "pending_sources": max(0, coverage.activeSources - coverage.indexedSources),
                "full_text_rows": coverage.ftsRows,
                "chunk_vectors": coverage.chunkVectors,
            ]
        }

        return try jsonString(payload)
    }

    /// iCloud sync health: the generation-2 coordinator's status (`generationTwoSyncStatus`).
    func getSyncStatus() async throws -> String {
        try await generationTwoSyncStatus()
    }

}

// MARK: - Errors

enum MCPError: LocalizedError {
    case database(String)
    case notFound(String)
    case invalidInput(String)
    case embeddingUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .database(let msg): return "Database error: \(msg)"
        case .notFound(let msg): return msg
        case .invalidInput(let msg): return msg
        case .embeddingUnavailable(let msg): return msg
        }
    }
}
