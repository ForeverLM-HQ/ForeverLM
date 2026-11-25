#if os(macOS)
import Foundation

// MARK: - The Map over MCP
//
// The Map is a plane for what the learner thinks: their Ideas, the regions
// they draw and the arrows between them, each Idea's sources hanging under it
// as evidence (docs/knowledge-map-design.md). A chat reads the map — what is
// placed where, the regions and arrows, each Idea's evidence, what is in
// view, what is circled — and shows a lens: the cards grouped, laid out on
// two axes, or set beside the concepts of a topic in the order they connect,
// until the learner keeps it or goes back to their own map. A lens can bring
// in any card in the library, placed or not. The arrangement is the
// learner's: the tools that place cards, draw regions and arrows, undo or keep
// a lens (`canvasEditToolNames`) do so only when the learner asks, each as one
// edit of theirs that Undo takes back. The tools answer from the app's one
// Studio view model, so they need the Mac.

extension MCPToolRegistry {
    static var knowledgeMapToolDefs: [MCPToolDef] {
        let itemIDs: [String: Any] = [
            "type": "array",
            "items": ["type": "string"],
            "description": "Cards by item_id as get_knowledge_map gives them: source:<source_id>, doc:<doc_id> (a Doc, site, animation, audio overview or reading), idea:<idea_id>, canvas:<canvas_id> (a shortcut to another canvas), chat:<session_id> (a chat) or picture:<image_id> (an image from list_images). A bare source, Doc or Idea id is accepted too.",
        ]
        let axis: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "What the axis measures, in the learner's words where they have them."],
                "low": ["type": "string", "description": "What its low end means."],
                "high": ["type": "string", "description": "What its high end means."],
            ],
            "required": ["label"],
        ]
        return [
            MCPToolDef(
                name: "get_knowledge_map",
                description: "Read the learner's Canvas: a zoomable plane for what they think, holding the Ideas (questions, claims, hunches) and other cards they placed, the regions they drew around them and the arrows between them; a source not placed is not on the plane unless it is an Idea's evidence. Returns the regions they drew (by name, with region_id and rect, and collapsed when folded up, its cards then placed but not drawn) with the cards placed in each, the cards placed outside any region, each placed Idea's evidence (the sources and Docs linked to it), the arrows they drew between cards with their labels and edge_id, what is in view right now (the zoom level, the regions and up to 60 cards on screen), the cards they selected or circled, the lens showing if any, and how many cards are not placed yet, by notebook. Every card has an item_id (source:<source_id>, doc:<doc_id> for a Doc or anything else a notebook made, idea:<idea_id>, page:<source_id>:<n> for one page of a PDF source laid out on the Canvas, drawn from the PDF, canvas:<canvas_id> for a shortcut to another canvas, chat:<session_id> for a chat, or picture:<image_id> for an image of the Images library) to pass to apply_map_lens, focus_map and the tools that edit the Canvas on the learner's word (place_on_canvas and the rest); a source's id works with every source tool and a Doc's with read_doc. A placed card also gives its rect (x, y and the width and height it is drawn at) and what the learner gave it (w, h, folded, color); a source drawn as a page of its PDF says which (page) and how many the PDF has (pages), and a card says the learner's words about why it is on this canvas (annotation), an Idea drawn as plain words (plain), an Idea whose title is a question (question) and a question marked answered (answered); a region says when it is locked and when its layout is a tree (a mind map); an arrow says its route (curve, straight or elbow), dashed, heads (end, both or none), color, its stance (supports or contradicts) and whether it is a tree branch, and an arrow's end may be a region (region:<region_id>); what is left out is the default. Call it when the learner talks about the canvas, the area they are looking at, a region, or what they circled, before answering about it. The learner may have several canvases in their Space; this reads the one open on the Mac, named in canvas (list_canvases lists them, open_canvas opens another).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_unplaced": [
                            "type": "boolean",
                            "description": "Also list the cards not placed yet, by notebook, up to limit. Defaults to false: only their counts.",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Most cards listed in any one list (default 200, at most 1000).",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "apply_map_lens",
                description: "Show a lens over the learner's Canvas: lay the cards you name out grouped under labels (layout groups), on two axes (layout axes), or beside the concepts of a topic in the order they connect (layout concepts), around where the learner is looking, and fade the rest. Any source, Doc or Idea in the library can be in a lens, placed on the canvas or not. The learner asked to see their material another way — \"group these by species\", \"plot them by how direct the measurement is against how alive the subject is\", \"zoom in on the PINK1–Parkin axis in Parkinson's and place the papers in context\" — and you decide each card's place by reading the sources (search tools, get_source_content) first. For a concepts lens, name the concepts or steps of the biology in your own words (\"PINK1 builds up on depolarised mitochondria\", \"Parkin is recruited and activated\", \"Ubiquitin chains mark the outer membrane\", \"Mitophagy\"), give each a one-sentence note and the papers that bear on it (a concept may have none), and link them in the direction the biology runs with a short label (\"phosphorylates\", \"recruits\"). A lens moves nothing the learner placed and is not saved: the banner over the canvas offers Keep, which places the cards where the lens put them and turns its groups or concepts into regions, and Back to My Canvas. Never call it to tidy the canvas on your own initiative. Opens the Canvas beside the chat if it is not showing. A new lens replaces the one showing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "The lens's name in the banner, e.g. \"By species\"."],
                        "layout": [
                            "type": "string",
                            "enum": ["groups", "axes", "concepts"],
                            "description": "groups: cards under labelled groups (pass groups). axes: cards placed on two axes (pass points, x_axis, y_axis). concepts: cards beside the concepts of a topic, laid out left to right in the order the links run (pass concepts and links).",
                        ],
                        "groups": [
                            "type": "array",
                            "description": "For layout groups: each group's label and its cards, in the order to show them. A card listed twice shows in its first group.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": ["type": "string"],
                                    "item_ids": itemIDs,
                                ],
                                "required": ["label", "item_ids"],
                            ],
                        ],
                        "concepts": [
                            "type": "array",
                            "description": "For layout concepts: each concept or step of the topic, in the order to stack them, with a one-sentence note and the cards that bear on it. A card listed twice shows under its first concept.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": ["type": "string", "description": "The concept's name, short."],
                                    "note": ["type": "string", "description": "One sentence on what it is or does, drawn under its name."],
                                    "item_ids": itemIDs,
                                ],
                                "required": ["label"],
                            ],
                        ],
                        "links": [
                            "type": "array",
                            "description": "For layout concepts: how one concept leads to another, by their labels, with a short label for the arrow. A concept nothing leads to is drawn on the left.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "from": ["type": "string"],
                                    "to": ["type": "string"],
                                    "label": ["type": "string"],
                                ],
                                "required": ["from", "to"],
                            ],
                        ],
                        "x_axis": axis,
                        "y_axis": axis,
                        "points": [
                            "type": "array",
                            "description": "For layout axes: each card's place, x and y from 0 (the axis's low end) to 1 (its high end).",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "item_id": ["type": "string"],
                                    "x": ["type": "number"],
                                    "y": ["type": "number"],
                                ],
                                "required": ["item_id", "x", "y"],
                            ],
                        ],
                        "hide_others": [
                            "type": "boolean",
                            "description": "Fade the cards the lens does not name almost away (default true), or only dim them.",
                        ],
                    ],
                    "required": ["title", "layout"],
                ]
            ),
            MCPToolDef(
                name: "clear_map_lens",
                description: "Take the lens off the learner's Canvas, so their own arrangement shows again. Nothing the lens showed is kept; the learner's Keep is the only way a lens becomes their canvas.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "focus_map",
                description: "Fly the learner's Canvas to cards or a region and ring them for a moment, or select them, so what you are talking about is on screen. Moves the view only, never a card. Opens the Canvas beside the chat if it is not showing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": itemIDs,
                        "region": ["type": "string", "description": "A region's name (as get_knowledge_map lists it) or its region_id."],
                        "select": ["type": "boolean", "description": "Select the cards, showing them in the Canvas side panel, instead of only ringing them. Defaults to false."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "place_on_canvas",
                description: "Set cards down on the learner's Canvas, or move ones already on it: into a region or a notebook's frame (region), beside a card already placed (beside), as a block with a new region drawn around it (new_region), or, with none of these, in free space in the middle of what the learner is looking at. Any source, Doc or Idea in the library can be placed; a card already on the Canvas moves. Cards in a region fill the free cells of its grid and the region grows to hold them; a notebook's frame lays its cards out in rows. Pass at most one of region, beside and new_region. Pass color, folded, w and h to give the cards set down a look of their own at once (update_canvas_card changes it later). A paper whose PDF is on the Mac is set down as page 1 of it, its title and authors under, rather than as a card (face card sets it down as the usual card; face page shows any source as its page); pass annotations to write the learner's reason for each card being there under it (update_canvas_card changes it later). Only on the learner's word: the Canvas is where they think, so never arrange it on your own initiative; to suggest an arrangement, show a lens (apply_map_lens) or ask_canvas. Each call is one edit of theirs, which Undo (⌘Z, or undo_canvas) takes back. Opens the Canvas beside the chat and flies to the cards. Returns the cards placed, the region they went into, and any item_ids the library does not hold.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": [
                            "type": "array",
                            "items": [
                                "type": "string",
                            ],
                            "description": "Cards by item_id as get_knowledge_map gives them: source:<source_id>, doc:<doc_id> (a Doc, site, animation, audio overview or reading), idea:<idea_id>, canvas:<canvas_id> (a shortcut to another canvas), chat:<session_id> (a chat) or picture:<image_id> (an image from list_images). A bare source, Doc or Idea id is accepted too.",
                            "minItems": 1,
                            "maxItems": 200,
                        ] as [String: Any],
                        "region": [
                            "type": "string",
                            "description": "Put the cards in this region: its name (as get_knowledge_map lists it; a notebook's frame by its notebook's name) or its region_id.",
                        ],
                        "beside": [
                            "type": "string",
                            "description": "Set the cards down as a block beside this card, which must be on the Canvas: by item_id (source:<id>, doc:<id> or idea:<id>; a bare id is tried as a source, then a Doc, then an Idea).",
                        ],
                        "new_region": [
                            "type": "string",
                            "description": "Draw a new region of this name around the cards, set down together in free space.",
                        ],
                        "color": [
                            "type": "string",
                            "description": "Tint the cards as #RRGGBB (the Canvas's own eight: #7F77DD, #1D9E75, #D85A30, #D4537E, #BA7517, #378ADD, #639922, #888780).",
                        ],
                        "folded": [
                            "type": "boolean",
                            "description": "Set the cards down folded to their title line.",
                        ],
                        "w": [
                            "type": "number",
                            "description": "Give the cards this width, 160 to 720 (a card is 240 wide unless asked).",
                        ],
                        "h": [
                            "type": "number",
                            "description": "Give the cards this height, 56 to 2000 (a card is as tall as its kind is unless asked).",
                        ],
                        "annotations": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "The learner's words about why a card is on this canvas, drawn under it, by item_id: at most 600 characters each. For any card set down in this call but an Idea, whose own note holds its words.",
                        ] as [String: Any],
                        "face": [
                            "type": "string",
                            "enum": ["page", "card"],
                            "description": "page: show sources as page 1 of their PDF; card: the usual card. Without it a paper whose PDF is on the Mac is set down as its page and every other card as itself.",
                        ],
                    ] as [String: Any],
                    "required": ["item_ids"],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "take_off_canvas",
                description: "Take cards off the learner's Canvas, as the inspector's Take Off Canvas does: each waits in the canvas's Library again (a notebook's source is drawn flat in its notebook's frame again when the frame is on the Canvas), and the arrows drawn to it go with it. Nothing is deleted from the library. Only on the learner's word: the Canvas is where they think, so never arrange it on your own initiative; to suggest an arrangement, show a lens (apply_map_lens) or ask_canvas. Each call is one edit of theirs, which Undo (⌘Z, or undo_canvas) takes back. Returns the cards taken off and those that were not on the Canvas.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": [
                            "type": "array",
                            "items": [
                                "type": "string",
                            ],
                            "description": "Cards by item_id as get_knowledge_map gives them: source:<source_id>, doc:<doc_id> (a Doc, site, animation, audio overview or reading), idea:<idea_id>, canvas:<canvas_id> (a shortcut to another canvas), chat:<session_id> (a chat) or picture:<image_id> (an image from list_images). A bare source, Doc or Idea id is accepted too.",
                            "minItems": 1,
                            "maxItems": 500,
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["item_ids"],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "canvas_region",
                description: "Draw, change or delete a region on the learner's Canvas. action create draws one: around item_ids (cards all on the Canvas keep their places and the region is drawn around them; otherwise they are set down together inside it), or empty in free space in the middle of what the learner is looking at; it needs a name. With notebook_id it is that notebook's frame: named by the notebook, drawing the notebook's ticked sources and Docs that are not placed anywhere, and folding into the notebook and its takeaways when zoomed out; a notebook whose frame is on the Canvas already is not framed twice (the answer names that frame). It opens the Canvas beside the chat, flies to the region and returns its region_id. action update changes the region named by region, as its inspector and its handle do: rename it (name; a notebook's frame takes its notebook's name, so rename the notebook with update_notebook), recolour it, move it (x, y: its top left, carrying the cards inside it), resize it (w, h), link it to a notebook as its frame (notebook_id; an empty string unlinks it), fold it up (collapsed true: it draws as its name and the count of its cards, which stay placed where they are but are not drawn, and arrows to them wait; false opens it again), lock it (locked true: its cards cannot be dragged, nor it moved or resized by hand, until it is unlocked; a locked region refuses the changes to its geometry and layout below unless the same call unlocks it), set its layout (layout tree: a mind map, its cards laid out once from the tree edges among them (canvas_arrow with tree) and then kept a tree by the Canvas; free: its cards stay where they are), fit it to what it holds (fit_to_content true: its cards and the regions inside it, with room for its name, never below 200 by 120) or grow it to hold cards (grow_to_hold: item_ids on the Canvas, with 24 to spare; it never shrinks). Positions are in the Canvas's own units, as get_knowledge_map gives each region's rect; a card is 240 by 120. It returns the region as it now is. action delete deletes the region named by region. Its cards stay where they are unless take_cards_off is true, which takes them off the Canvas too and deletes the regions inside it, in the same edit; a notebook's frame going takes nothing out of the notebook. Only on the learner's word: the Canvas is where they think, so never arrange it on your own initiative; to suggest an arrangement, show a lens (apply_map_lens) or ask_canvas. Each call is one edit of theirs, which Undo (⌘Z, or undo_canvas) takes back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["create", "update", "delete"], "description": "create, update or delete."] as [String: Any],
                        "region": ["type": "string", "description": "For update and delete: a region's name (as get_knowledge_map lists it; a notebook's frame by its notebook's name) or its region_id."] as [String: Any],
                        "name": ["type": "string", "description": "create: the region's name, required unless notebook_id is given. update: its new name."] as [String: Any],
                        "item_ids": ["type": "array", "items": ["type": "string"], "description": "create: the cards to draw it around or set down inside it. Cards by item_id as get_knowledge_map gives them: source:<source_id>, doc:<doc_id> (a Doc, site, animation, audio overview or reading), idea:<idea_id>, canvas:<canvas_id> (a shortcut to another canvas), chat:<session_id> (a chat) or picture:<image_id> (an image from list_images). A bare source, Doc or Idea id is accepted too."] as [String: Any],
                        "notebook_id": ["type": "string", "description": "Make the region this Notebook's frame (a Notebook id from list_notebooks); on update, an empty string unlinks it."] as [String: Any],
                        "color": ["type": "string", "description": "The region's tint as #RRGGBB. The Canvas's own: #7F77DD, #1D9E75, #D85A30, #D4537E, #BA7517, #378ADD, #639922, #888780. Omit for the next one."] as [String: Any],
                        "locked": ["type": "boolean", "description": "Lock the region (true) or unlock it (false). On create it defaults to false."] as [String: Any],
                        "x": ["type": "number", "description": "update: its new left edge."] as [String: Any],
                        "y": ["type": "number", "description": "update: its new top edge."] as [String: Any],
                        "w": ["type": "number", "description": "update: its new width."] as [String: Any],
                        "h": ["type": "number", "description": "update: its new height."] as [String: Any],
                        "collapsed": ["type": "boolean", "description": "update: fold the region up (true) or open it again (false)."] as [String: Any],
                        "layout": ["type": "string", "enum": ["free", "tree"], "description": "update: tree, a mind map, laid out once from the tree edges among its cards; free, its cards stay where they are."] as [String: Any],
                        "fit_to_content": ["type": "boolean", "description": "update: fit the region to its cards and the regions inside it."] as [String: Any],
                        "grow_to_hold": ["type": "array", "items": ["type": "string"], "description": "update: grow the region to hold these cards (item_ids on the Canvas) whole, with 24 to spare."] as [String: Any],
                        "take_cards_off": ["type": "boolean", "description": "delete: take the cards inside it off the Canvas and delete the regions inside it as well. Defaults to false."] as [String: Any],
                    ] as [String: Any],
                    "required": ["action"],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "canvas_arrow",
                description: "Draw, change or delete an arrow on the learner's Canvas. action draw draws one between two cards (from and to), with a short label for how one leads to the other (supports, contradicts, explains, causes, measures, extends, example of, or the learner's own words). Both cards must be on the Canvas (place_on_canvas first); an arrow already drawn between them gets the label and what else is given. An end may be a region instead of a card (region:<region_id>, or region:<name>): an arrow to a region survives its cards leaving and goes with the region; a card is not joined to the region that holds it, nor a region to one around or inside it. Give the arrow a look: route (curve, the default; straight; or elbow), dashed, heads (end, the default; both; or none), color (#RRGGBB) and a stance (supports draws it green, contradicts red, unless it has a color of its own). With tree true it is a mind-map branch, parent to child, drawn as a branch and not an arrow: a branch joins two cards, a card has one parent, and a tree has no loop (canvas_region, action update, with layout tree lays a region of such cards out as a mind map). It returns the arrow's edge_id. action update changes an arrow named by its edge_id (get_knowledge_map lists it under arrows) or by its ends (from and to): relabel it (label; an empty label clears it), set its route, dashed, heads or color (an empty string gives it the usual one), put it on a side of an argument (stance; an empty string takes it off), or turn it into a mind-map branch or back into an arrow (tree). Pass only what changes. action delete deletes the arrow named by its edge_id or by its ends; the cards stay. Only on the learner's word: the Canvas is where they think, so never arrange it on your own initiative; to suggest an arrangement, show a lens (apply_map_lens) or ask_canvas. Each call is one edit of theirs, which Undo (⌘Z, or undo_canvas) takes back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["draw", "update", "delete"], "description": "draw, update or delete."] as [String: Any],
                        "edge_id": ["type": "string", "description": "For update and delete: the arrow's edge_id, instead of from and to."] as [String: Any],
                        "from": ["type": "string", "description": "Where the arrow starts: a card by item_id, or a region as region:<region_id>."] as [String: Any],
                        "to": ["type": "string", "description": "Where the arrow points to: a card by item_id, or a region as region:<region_id>."] as [String: Any],
                        "label": ["type": "string", "description": "A few words on the arrow; on update an empty label clears it."] as [String: Any],
                        "route": ["type": "string", "enum": ["curve", "straight", "elbow"], "description": "How the arrow runs: a gentle curve (the default), a straight line or an elbow."] as [String: Any],
                        "dashed": ["type": "boolean", "description": "Draw the line dashed (true) or solid (false)."] as [String: Any],
                        "heads": ["type": "string", "enum": ["end", "both", "none"], "description": "Where the arrowheads are: at the end (the default), at both ends or nowhere."] as [String: Any],
                        "color": ["type": "string", "description": "The arrow's color as #RRGGBB; on update an empty string gives it the usual one."] as [String: Any],
                        "tree": ["type": "boolean", "description": "Make it a mind-map branch from the parent (from) to the child (to) (true), or a plain arrow again (false)."] as [String: Any],
                        "stance": ["type": "string", "description": "supports (drawn green) or contradicts (red); on update an empty string takes the stance off."] as [String: Any],
                    ] as [String: Any],
                    "required": ["action"],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "build_canvas",
                description: "Lay a whole picture out on one of the learner's canvases in one call, on their word (\"lay this paper out visually on a canvas\", \"mock up how these ideas connect\"): write note cards, set them and cards from the library down in labelled groups, and draw arrows between them. Each note is an Idea of the learner's (a card with a title and a few lines of text; it is also linked to the canvas's notebook when the canvas belongs to one) that you author: a claim, a step, a question, a caveat. A note with source_id and quote is instead a passage card: the words are marked as a highlight in that source (the one the learner already has on them is reused), the card shows them, and clicking it opens the paper at those words, so quote the paper wherever a claim rests on it. Each group becomes a region of that name around its cards, set down in the order given, left to right; a card in no group is set down in free space. Cards from the library are named by item_id (source:<id>, doc:<id>, idea:<id>, canvas:<id> for a shortcut to another canvas, chat:<session_id>, picture:<image_id>), notes by the key you gave them. Arrows join two cards, each a note key or an item_id, with an optional short label. Keep what is observed apart from what is interpreted by putting them in different groups, and give each region a colour with the same meaning. A mind map is a tree: each trees entry names a region and a root note with nested children notes (all Ideas of the learner's, written the same way), set down left to right inside that region (the root at the left, each child to the right of its parent, a parent centred on its children), joined by tree branches, and the region's layout is a mind map so the Canvas keeps it one; a note in a tree may be named by its key in arrows. A paper can be laid out as its own pages too: each pdf_pages entry names a source with a PDF (a paper, or a book or hand-out kept as one), and its pages are set down as cards drawn from the PDF itself, one per page, left to right in a region named for the source, a row below the last, before the groups; name them page:<source_id>:<n> in groups and arrows, limit them to a range such as \"1-8\" (at most 60 at a time), and set collapsed to fold the region up to its name and count until the learner opens it. A talk can be laid out as its slides: each talks entry names a YouTube video or a meeting recording, and its slides are set down as a storyboard, the papers each slide cites that are in the library hung under it with an arrow from the slide. A paper whose PDF is on the Mac is set down as its first page, its title and authors under it, rather than as a card. Pass annotations (a note key or item_id to the words) to write the learner's reason for a card being on the canvas under it: any card but a note, whose own text holds its words; and give an arrow a stance (supports draws it green, contradicts red) to argue a claim. Nothing the learner already placed moves. Pass canvas_id (list_canvases) to build on a canvas other than the open one; it is opened. Returns the notes and passages made with their item_ids, the regions drawn, the mind maps laid out (trees: the region, the root and each note with its item_id), the pages laid out (pdf_pages: the region, the page count and each page's item_id), the talks laid out (talks: the region, the slides' and papers' item_ids and how many cited papers are not in the library) and the arrows drawn, and anything it could not resolve. One Undo step takes back everything it set down and drew, but the Ideas it made stay in the learner's Ideas. A card named in a group that is on the canvas already stays where it is (listed as already_on_canvas) and still takes its annotation and arrows.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases. Defaults to the canvas open on the Mac."],
                        "notes": [
                            "type": "array",
                            "description": "Note cards to write, at most 60.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "key": ["type": "string", "description": "A short name to refer to this note by in groups and arrows, unique among the notes."],
                                    "title": ["type": "string", "description": "The card's heading: a short claim or label. Not used for a passage."],
                                    "text": ["type": "string", "description": "A few lines under the heading: the evidence, the caveat, the detail. For a passage, the learner's note on it."],
                                    "source_id": ["type": "string", "description": "With quote: the source the passage is from (list_sources)."],
                                    "quote": ["type": "string", "description": "Makes this note a passage card: the words, copied verbatim from get_source_content, marked as a highlight in source_id. The card shows them, and a click on it opens the paper at them."],
                                ],
                                "required": ["key"],
                            ],
                        ] as [String: Any],
                        "trees": [
                            "type": "array",
                            "description": "Mind maps to lay out, at most 10, with at most 120 notes in all: each a region of the given name holding a tree of notes, the root at the left and each child to the right of its parent.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string", "description": "The region's name, e.g. the question the map explores."],
                                    "color": ["type": "string", "description": "Optional region colour as #RRGGBB."],
                                    "root": [
                                        "type": "object",
                                        "description": "The root note. children holds its child notes, each of the same shape, which may have children of their own.",
                                        "properties": [
                                            "key": ["type": "string", "description": "Optional name to refer to this note by in arrows, unique among all the notes."],
                                            "title": ["type": "string", "description": "The note's heading: a short claim or label."],
                                            "text": ["type": "string", "description": "A few lines under the heading. Optional."],
                                            "children": [
                                                "type": "array",
                                                "description": "Child notes, in the order to show them top to bottom, each with key, title, text and children as here.",
                                                "items": ["type": "object"],
                                            ] as [String: Any],
                                        ] as [String: Any],
                                        "required": ["title"],
                                    ] as [String: Any],
                                ] as [String: Any],
                                "required": ["name", "root"],
                            ] as [String: Any],
                        ] as [String: Any],
                        "groups": [
                            "type": "array",
                            "description": "Labelled regions, at most 20, set down left to right in this order.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string", "description": "The region's name."],
                                    "color": ["type": "string", "description": "Optional region colour as #RRGGBB."],
                                    "items": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                        "description": "The cards in it, in reading order: note keys and item_ids.",
                                    ] as [String: Any],
                                ],
                                "required": ["name", "items"],
                            ],
                        ] as [String: Any],
                        "ungrouped": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Cards (note keys or item_ids) to set down together in free space, in no region.",
                        ] as [String: Any],
                        "annotations": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "The learner's words about why a card is on the canvas, drawn under it, by note key (a passage) or item_id: at most 600 characters each. Not for an Idea or a note, whose own text holds its words.",
                        ] as [String: Any],
                        "pdf_pages": [
                            "type": "array",
                            "description": "PDF sources to lay out as their pages, at most 10: each is set down as a row of cards, one per page, left to right in a region named for the source, before the groups.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "source_id": ["type": "string", "description": "A source with a PDF on the Mac: a paper, or a book or hand-out kept as a PDF (list_sources)."],
                                    "pages": ["type": "string", "description": "Which pages, one-based: a range such as \"1-8\" or \"2,5,7-9\". Defaults to all, at most 60 at a time; ask again with another range for the rest. Ignored when show is figures or figures_extended."],
                                    "show": ["type": "string", "enum": ["pages", "figures", "figures_extended"], "description": "What the row holds: pages (default), figures (one clip card per main figure, cut from its page by the paper's printed captions and named by its label, as the Reader's Clip tool cuts one; the extended and supplementary figures left out), or figures_extended (the extended and supplementary figures too, after the main ones). Figures need a paper with printed figure captions; the cards are item_ids of the kind clip:<id>."],
                                    "collapsed": ["type": "boolean", "description": "Fold the region up so only its name and count show until the learner opens it. Defaults to false."],
                                    "color": ["type": "string", "description": "Optional region colour as #RRGGBB."],
                                ],
                                "required": ["source_id"],
                            ],
                        ] as [String: Any],
                        "talks": [
                            "type": "array",
                            "description": "Videos or meeting recordings to lay out as their slides, at most 5: each is a storyboard of slide cards (clip:<id>, four to a row in the order shown, captured first if they never were), each slide with the papers it cites that are in the library hung under it and an arrow from the slide to each, in a region named for the talk, before the groups. Papers its slides cite that are not in the library are counted, not added (list_video_cited_papers, import_video_cited_paper); cited_papers_recorded 0 means the slides were never read for citations (scan_video_for_cited_papers) or cite nothing; a talk laid out before keeps its slides where they are and hangs the papers added since under theirs.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "source_id": ["type": "string", "description": "A YouTube video or a meeting with a recording (list_sources)."],
                                ],
                                "required": ["source_id"],
                            ],
                        ] as [String: Any],
                        "arrows": [
                            "type": "array",
                            "description": "Arrows to draw, at most 100.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "from": ["type": "string", "description": "A note key or an item_id."],
                                    "to": ["type": "string", "description": "A note key or an item_id."],
                                    "label": ["type": "string", "description": "A short label on the arrow, e.g. \"measured by\"."],
                                    "route": ["type": "string", "enum": ["curve", "straight", "elbow"], "description": "How it runs (default curve)."],
                                    "dashed": ["type": "boolean", "description": "Draw it dashed."],
                                    "heads": ["type": "string", "enum": ["end", "both", "none"], "description": "Where its heads are (default end)."],
                                    "color": ["type": "string", "description": "Its color as #RRGGBB."],
                                    "stance": ["type": "string", "enum": ["supports", "contradicts"], "description": "Which side of an argument it is on: supports (drawn green) or contradicts (red)."],
                                ],
                                "required": ["from", "to"],
                            ],
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "undo_canvas",
                description: "Undo the learner's last edit of their Canvas on this Mac, as ⌘Z there does, whether they made it by hand or asked for it here; with redo true, do again the edit last undone. Edits made within a moment of each other are one step. Returns whether there is more to undo and to redo.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "redo": [
                            "type": "boolean",
                            "description": "Redo instead of undo. Defaults to false.",
                        ],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "keep_map_lens",
                description: "Keep the lens showing on the learner's Canvas, as its banner's Keep does: each card in it is placed where the lens put it and its groups or concepts become regions. Only when the learner has said to keep it; clear_map_lens goes back to their own Canvas instead. Undo takes it back. Returns how many cards were placed and regions drawn.",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            ),
            MCPToolDef(
                name: "set_canvas_display",
                description: "Turn the learner's Canvas display switches on or off on this Mac, as the buttons beside its caption toggle do: memory_layer (each card marked by how the kept Memory cards behind it stand: holding, due, fading), written_faces (source cards read as a few words, a sentence or their question, approach and finding, by zoom) and view_captions (a sentence or two on what is in view after the learner pauses; each caption is a call to their Canvas Summaries model, so turn it on only when asked). Omitted switches stay as they are. Returns all three as they now are.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "memory_layer": [
                            "type": "boolean",
                            "description": "Show the Memory layer.",
                        ],
                        "written_faces": [
                            "type": "boolean",
                            "description": "Show source cards' written faces.",
                        ],
                        "view_captions": [
                            "type": "boolean",
                            "description": "Write a caption for what is in view.",
                        ],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            ),
        ] + canvasParityToolDefs
    }

    /// The tools that read the Canvas or change only what is on screen: the
    /// map, a lens, a focus, a check of the layout and a picture of it.
    static let knowledgeMapToolNames = Set(["get_knowledge_map", "apply_map_lens", "clear_map_lens", "focus_map", "lint_canvas", "screenshot_canvas"])
        .union(canvasEditToolNames)

    /// The tools that change the learner's Canvas, each on their word: the
    /// cards, regions and arrows they would otherwise place by hand, Undo,
    /// keeping a lens and the display switches.
    static let canvasEditToolNames: Set<String> = [
        "place_on_canvas", "take_off_canvas",
        "canvas_region", "canvas_arrow",
        "undo_canvas", "keep_map_lens", "set_canvas_display",
        "build_canvas",
        // A canvas's named versions: kept, and put back as one edit that
        // undo_canvas takes back (MCPTools+CanvasVersions.swift; its
        // listing, list_canvas_versions, is a catalogue tool).
        "save_canvas_version", "restore_canvas_version",
        // The parity build: a card's look, Tidy Up and Align (MCPTools+CanvasParity.swift).
        "update_canvas_card", "arrange_on_canvas",
    ]
}

extension MCPDataStore {
    func executeKnowledgeMapTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "get_knowledge_map":
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 200, 1), 1000)
            return try jsonString(try await Self.knowledgeMapSnapshot(
                includeUnplaced: arguments["include_unplaced"] as? Bool ?? false,
                limit: limit
            ))
        case "apply_map_lens":
            let request = try Self.lensRequest(from: arguments)
            return try jsonString(try await Self.applyKnowledgeMapLens(request))
        case "clear_map_lens":
            return try jsonString(try await Self.clearKnowledgeMapLens())
        case "focus_map":
            return try jsonString(try await Self.focusKnowledgeMap(
                itemIDs: arguments["item_ids"] as? [String] ?? [],
                region: (arguments["region"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                select: arguments["select"] as? Bool ?? false
            ))
        case "lint_canvas":
            return try jsonString(try await Self.lintOpenCanvas(arguments))
        case "screenshot_canvas":
            // The picture goes out as an image part when called through the
            // media path; this answers the text of the same call.
            let picture = await screenshotCanvas(arguments: arguments)
            return picture.text
        case "build_canvas":
            // Everything a call gets wrong is refused before anything is written:
            // no passage marked, no Idea made, nothing laid out.
            try await Self.validateBuildCanvas(arguments)
            // A note quoting a passage of a source is a highlight in that
            // source, made here, and a card that opens the paper at it.
            var plain: [[String: Any]] = []
            var passages: [String: String] = [:]
            for note in arguments["notes"] as? [[String: Any]] ?? [] {
                let quote = (note["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !quote.isEmpty else { plain.append(note); continue }
                let key = (note["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !key.isEmpty else { throw MCPError.invalidInput("Every note needs a key.") }
                guard passages[key] == nil, !plain.contains(where: { ($0["key"] as? String) == key }) else {
                    throw MCPError.invalidInput("Two notes share the key \(key).")
                }
                guard let sourceID = (note["source_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty else {
                    throw MCPError.invalidInput("The note \(key) quotes a passage, so it needs the source_id it is from.")
                }
                passages[key] = try passageHighlightID(sourceID: sourceID, quote: quote, note: note["text"] as? String)
            }
            var rest = arguments
            rest["notes"] = plain
            return try jsonString(try await Self.buildCanvas(arguments: rest, passages: passages))
        case _ where MCPToolRegistry.canvasEditToolNames.contains(name):
            return try jsonString(try await Self.editCanvas(name, arguments: arguments))
        default:
            return nil
        }
    }

    /// The highlight a passage note stands for: the mark the learner already
    /// has on that passage, else a new one in the source, exactly as
    /// create_source_highlight makes it.
    private func passageHighlightID(sourceID: String, quote: String, note: String?) throws -> String {
        func id(in json: String) -> String? {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mark = object["highlight"] as? [String: Any] else { return nil }
            return mark["highlight_id"] as? String
        }
        do {
            let created = try createSourceHighlight(sourceID: sourceID, quote: quote, note: note, color: nil)
            if let made = id(in: created) { return made }
        } catch MCPError.invalidInput(let message) {
            guard let range = message.range(of: "highlight_id: "),
                  let end = message[range.upperBound...].firstIndex(of: ")") else { throw MCPError.invalidInput(message) }
            return String(message[range.upperBound..<end])
        }
        throw MCPError.invalidInput("The passage could not be marked in \(sourceID).")
    }

    /// Parses apply_map_lens's arguments into a request. Ids are resolved
    /// against the map on the main actor, so a bare id is kept as given here.
    static func lensRequest(from arguments: [String: Any]) throws -> KnowledgeMapLensRequest {
        let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw MCPError.invalidInput("apply_map_lens needs a title for the lens.") }
        guard let rawLayout = arguments["layout"] as? String,
              let layout = KnowledgeMapLensRequest.Layout(rawValue: rawLayout) else {
            throw MCPError.invalidInput("apply_map_lens needs layout: groups, axes or concepts.")
        }
        var request = KnowledgeMapLensRequest(title: title, layout: layout)
        request.hidesOthers = arguments["hide_others"] as? Bool ?? true
        func ref(_ raw: String) -> KnowledgeMap.ItemRef {
            KnowledgeMap.ItemRef(raw) ?? KnowledgeMap.ItemRef(kind: .source, id: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func axis(_ value: Any?) -> KnowledgeMapLensRequest.Axis? {
            guard let dict = value as? [String: Any],
                  let label = (dict["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
            return .init(label: label, low: dict["low"] as? String ?? "", high: dict["high"] as? String ?? "")
        }
        switch layout {
        case .groups:
            let groups = arguments["groups"] as? [[String: Any]] ?? []
            request.groups = groups.compactMap { group in
                guard let label = (group["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                return .init(label: label, items: (group["item_ids"] as? [String] ?? []).map(ref))
            }
            guard !request.groups.isEmpty else { throw MCPError.invalidInput("A groups lens needs groups, each with a label and item_ids.") }
        case .axes:
            request.xAxis = axis(arguments["x_axis"])
            request.yAxis = axis(arguments["y_axis"])
            guard request.xAxis != nil, request.yAxis != nil else {
                throw MCPError.invalidInput("An axes lens needs x_axis and y_axis, each with a label.")
            }
            let points = arguments["points"] as? [[String: Any]] ?? []
            request.points = points.compactMap { point in
                guard let raw = point["item_id"] as? String,
                      let x = (point["x"] as? NSNumber)?.doubleValue,
                      let y = (point["y"] as? NSNumber)?.doubleValue else { return nil }
                return .init(item: ref(raw), x: x, y: y)
            }
            guard !request.points.isEmpty else { throw MCPError.invalidInput("An axes lens needs points, each with an item_id, x and y.") }
        case .concepts:
            let concepts = arguments["concepts"] as? [[String: Any]] ?? []
            request.concepts = concepts.compactMap { concept in
                guard let label = (concept["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                return .init(label: label, note: concept["note"] as? String ?? "", items: (concept["item_ids"] as? [String] ?? []).map(ref))
            }
            guard !request.concepts.isEmpty else { throw MCPError.invalidInput("A concepts lens needs concepts, each with a label.") }
            let links = arguments["links"] as? [[String: Any]] ?? []
            request.conceptLinks = links.compactMap { link in
                guard let from = link["from"] as? String, let to = link["to"] as? String else { return nil }
                return .init(from: from, to: to, label: link["label"] as? String ?? "")
            }
        }
        return request
    }

    // MARK: Main-actor work

    @MainActor
    static func preparedMap(opening: Bool) async throws -> (StudioViewModel, KnowledgeMapModel) {
        let studio = try AppModelBridge.requireStudio()
        if studio.knowledgeMap.content.nodes.isEmpty {
            await studio.refreshKnowledgeMapContent()
        }
        if opening, !studio.knowledgeMapIsOnScreen {
            studio.openCenterTabBeside(.knowledgeMap)
        }
        return (studio, studio.knowledgeMap)
    }

    @MainActor
    static func knowledgeMapSnapshot(includeUnplaced: Bool, limit: Int) async throws -> [String: Any] {
        let (studio, map) = try await preparedMap(opening: false)
        // A notebook frame's takeaways come from the summary cache.
        await map.summaryCacheLoaded()
        let layout = map.layout
        let placedRefs = layout.placements.keys.filter { map.nodesByRef[$0] != nil }.sorted { map.title(of: $0) < map.title(of: $1) }
        var byRegion: [String: [String]] = [:]
        var outside: [String] = []
        for ref in placedRefs {
            if let region = map.regionID(containing: ref) { byRegion[region, default: []].append(ref) } else { outside.append(ref) }
        }
        let regions: [[String: Any]] = layout.regions
            .sorted { ($0.value.y, $0.value.x) < ($1.value.y, $1.value.x) }
            .map { id, region in
                var cards = byRegion[id] ?? []
                var entry: [String: Any] = [
                    "region_id": id,
                    "name": region.name.isEmpty ? "Untitled region" : region.name,
                    // Where it is, for canvas_region (action update): a card is 240 by 120.
                    "rect": ["x": region.x, "y": region.y, "w": region.w, "h": region.h],
                ]
                // A notebook's frame: named by the notebook, and drawing its
                // cards that are not placed anywhere too.
                if let notebook = map.notebook(ofRegion: id) {
                    entry["name"] = notebook.title
                    entry["notebook_id"] = notebook.id
                    cards += notebook.refs.filter { layout.placements[$0] == nil && !cards.contains($0) }
                    if let takeaways = map.summaries["r:" + id]?.takeaways, !takeaways.isEmpty { entry["takeaways"] = takeaways }
                }
                if region.isCollapsed { entry["collapsed"] = true }
                if region.isLocked { entry["locked"] = true }
                if region.isTree { entry["layout"] = KnowledgeMapLayout.treeLayout }
                entry["card_count"] = cards.count
                entry["cards"] = cards.prefix(limit).map { card($0, in: map) }
                // A region drawn inside another: the one around it, and the
                // ones inside it, whose cards are theirs, not this one's.
                if let parent = layout.parentRegionID(of: id) { entry["parent_region_id"] = parent }
                let nested = layout.nestedRegionIDs(in: id)
                if !nested.isEmpty { entry["nested_region_ids"] = nested }
                return entry
            }
        let arrows: [[String: Any]] = layout.edges
            .sorted { ($0.value.from, $0.value.to) < ($1.value.from, $1.value.to) }
            .prefix(limit)
            .map { id, _ in arrowEntry(id, in: map) }
        let ideaEvidence: [[String: Any]] = placedRefs
            .filter { KnowledgeMap.ItemRef($0)?.kind == .idea }
            .compactMap { ref in
                let evidence = map.evidence(of: ref)
                guard !evidence.isEmpty else { return nil }
                return ["idea": card(ref, in: map), "evidence": evidence.prefix(limit).map { card($0, in: map) }]
            }
        let unplaced = map.content.nodes.filter { layout.placements[$0.ref] == nil }
        var unplacedByNotebook: [String: [KnowledgeMapNode]] = [:]
        for node in unplaced { unplacedByNotebook[node.shore, default: []].append(node) }
        let unplacedList: [[String: Any]] = unplacedByNotebook.keys.sorted().map { notebook in
            let nodes = unplacedByNotebook[notebook] ?? []
            var entry: [String: Any] = ["notebook": notebook, "count": nodes.count]
            if includeUnplaced { entry["cards"] = nodes.prefix(limit).map { card($0.ref, in: map) } }
            return entry
        }
        let view = map.viewport
        let regionNames = view.visibleRegionIDs.compactMap { layout.regions[$0] }.map { $0.name.isEmpty ? "Untitled region" : $0.name }
        var result: [String: Any] = [
            // Which of the learner's canvases this is: the one open on the Mac.
            "canvas": ["canvas_id": map.mapID, "name": studio.openCanvasName],
            "map_open": studio.knowledgeMapIsOnScreen,
            "placed_card_count": placedRefs.count,
            "unplaced_card_count": unplaced.count,
            "regions": regions,
            "cards_outside_regions": outside.prefix(limit).map { card($0, in: map) },
            "arrows": arrows,
            "idea_evidence": ideaEvidence,
            "unplaced_by_notebook": unplacedList,
            "selection": map.selection.prefix(limit).map { card($0, in: map) },
            "view": [
                "zoom_level": view.level,
                "regions_in_view": regionNames,
                "cards_in_view_count": view.visibleRefs.count,
                "cards_in_view": view.visibleRefs.prefix(60).map { card($0, in: map) },
            ] as [String: Any],
        ]
        if let lens = map.lens {
            result["lens"] = ["title": lens.title, "card_count": lens.positions.count]
        }
        return result
    }

    @MainActor
    static func applyKnowledgeMapLens(_ request: KnowledgeMapLensRequest) async throws -> [String: Any] {
        let (_, map) = try await preparedMap(opening: true)
        var resolvedRequest = request
        resolvedRequest.groups = request.groups.map { .init(label: $0.label, items: $0.items.map { resolved($0, in: map) }) }
        resolvedRequest.points = request.points.map { .init(item: resolved($0.item, in: map), x: $0.x, y: $0.y) }
        resolvedRequest.concepts = request.concepts.map { .init(label: $0.label, note: $0.note, items: $0.items.map { resolved($0, in: map) }) }
        let unknown = resolvedRequest.items.filter { map.nodesByRef[$0.description] == nil }.map(\.description)
        let lens: KnowledgeMapLens
        do {
            lens = try map.apply(resolvedRequest)
        } catch {
            throw MCPError.invalidInput(error.localizedDescription + (unknown.isEmpty ? "" : " Not on the canvas: \(unknown.prefix(20).joined(separator: ", "))."))
        }
        var result: [String: Any] = [
            "shown": true,
            "title": lens.title,
            "card_count": lens.positions.count,
            "note": "The learner sees the lens with Keep and Back to My Canvas; nothing is placed until they press Keep.",
        ]
        if !unknown.isEmpty { result["not_on_map"] = Array(unknown.prefix(50)) }
        return result
    }

    @MainActor
    static func clearKnowledgeMapLens() async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let hadLens = studio.knowledgeMap.lens != nil
        studio.knowledgeMap.clearLens()
        return ["cleared": hadLens]
    }

    @MainActor
    static func focusKnowledgeMap(itemIDs: [String], region: String?, select: Bool) async throws -> [String: Any] {
        let (studio, map) = try await preparedMap(opening: true)
        await refreshUnknownKinds(itemIDs, in: studio)
        // Only cards on the canvas can be shown or selected there.
        let refs = itemIDs
            .map { KnowledgeMap.ItemRef($0) ?? KnowledgeMap.ItemRef(kind: .source, id: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { resolved($0, in: map).description }
            .filter { map.nodesByRef[$0] != nil && map.layout.placements[$0] != nil }
        // A region by its id, its name, or the title of the notebook it frames, as get_knowledge_map lists it.
        var regionID: String?
        if let region, !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            regionID = try Self.regionID(region, in: map)
        }
        guard !refs.isEmpty || regionID != nil else {
            throw MCPError.invalidInput("focus_map needs item_ids that are on the canvas, or a region.")
        }
        if select, !refs.isEmpty {
            map.selection = refs
            map.send(.select(refs: refs))
        } else {
            map.send(.focus(refs: refs, regionID: regionID))
        }
        return ["focused": refs.count, "region_id": regionID ?? NSNull()]
    }

    // MARK: Editing the Canvas on the learner's word

    /// Everything build_canvas can refuse, checked before it writes anything:
    /// the canvas, the limits, each note's key and title (unique across notes,
    /// passages and tree notes), each group's name and colour, the trees, the
    /// arrows' looks, the annotations, and a lens standing on the canvas.
    @MainActor
    static func validateBuildCanvas(_ arguments: [String: Any]) async throws {
        let studio = try AppModelBridge.requireStudio()
        var target: String?
        if let id = (arguments["canvas_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            studio.refreshCanvasesFromRows()
            guard studio.canvases.canvas(id) != nil else {
                throw MCPError.notFound("No canvas has canvas_id \(id); list_canvases lists them.")
            }
            target = id
        }
        let notes = arguments["notes"] as? [[String: Any]] ?? []
        let groups = arguments["groups"] as? [[String: Any]] ?? []
        let ungrouped = arguments["ungrouped"] as? [String] ?? []
        let arrows = arguments["arrows"] as? [[String: Any]] ?? []
        let pdfPages = arguments["pdf_pages"] as? [[String: Any]] ?? []
        let trees = arguments["trees"] as? [[String: Any]] ?? []
        let talks = arguments["talks"] as? [[String: Any]] ?? []
        guard notes.count <= 60, groups.count <= 20, arrows.count <= 100, pdfPages.count <= 10, trees.count <= 10, talks.count <= 5 else {
            throw MCPError.invalidInput("At most 60 notes, 20 groups, 100 arrows, 10 pdf_pages, 10 trees and 5 talks in one call.")
        }
        guard !(notes.isEmpty && groups.isEmpty && ungrouped.isEmpty && pdfPages.isEmpty && trees.isEmpty && talks.isEmpty) else {
            throw MCPError.invalidInput("build_canvas needs notes, groups, trees, pdf_pages, talks or ungrouped cards to set down.")
        }
        var keys = Set<String>()
        for note in notes {
            let key = (note["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { throw MCPError.invalidInput("Every note needs a key.") }
            let quote = (note["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (note["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if quote.isEmpty, title.isEmpty { throw MCPError.invalidInput("Every note needs a title (or a quote, with its source_id).") }
            guard keys.insert(key).inserted else { throw MCPError.invalidInput("Two notes share the key \(key).") }
        }
        let specs = try treeSpecs(from: trees)
        for (index, spec) in specs.enumerated() {
            for (position, note) in spec.notes.enumerated() {
                let key = note.key ?? "tree\(index + 1).\(position + 1)"
                guard keys.insert(key).inserted else { throw MCPError.invalidInput("Two notes share the key \(key).") }
            }
        }
        for group in groups {
            let name = (group["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { throw MCPError.invalidInput("Every group needs a name.") }
            _ = try regionColor(group["color"])
        }
        for entry in pdfPages {
            _ = try regionColor(entry["color"])
            let show = (entry["show"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "pages"
            guard KnowledgeMapPaperLayout(rawValue: show) != nil else {
                throw MCPError.invalidInput("pdf_pages show must be pages, figures or figures_extended, not \"\(show)\".")
            }
        }
        for arrow in arrows {
            _ = try edgeRoute(arrow["route"])
            _ = try edgeHeads(arrow["heads"])
            _ = try edgeColor(arrow["color"])
            _ = try edgeStance(arrow["stance"])
        }
        if let given = arguments["annotations"], !(given is NSNull) {
            guard let object = given as? [String: Any] else { throw MCPError.invalidInput("annotations is an object of note key or item_id to words.") }
            for (key, raw) in object {
                let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let text = raw as? String else { throw MCPError.invalidInput("The annotation for \(name) is text.") }
                let quoted = notes.contains { ($0["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == name && !(($0["quote"] as? String) ?? "").isEmpty }
                if (keys.contains(name) && !quoted) || name.hasPrefix("idea:") {
                    throw MCPError.invalidInput("An Idea's own note holds its words, so \(name) takes no annotation; give annotations to the library's cards and the passages quoted.")
                }
                _ = try cardAnnotation(text)
            }
        }
        // A lens on the canvas being built on waits for the learner.
        if target == nil || target == studio.knowledgeMap.mapID, studio.knowledgeMap.lens != nil {
            throw MCPError.invalidInput("A lens shows on the Canvas: keep it (keep_map_lens) or clear it (clear_map_lens) first, as the learner's own edits wait for it.")
        }
    }

    /// build_canvas: notes, groups and arrows laid out on a canvas in one call.
    @MainActor
    private static func buildCanvas(arguments: [String: Any], passages: [String: String]) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        if let id = (arguments["canvas_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            studio.refreshCanvasesFromRows()
            guard studio.canvases.canvas(id) != nil else {
                throw MCPError.notFound("No canvas has canvas_id \(id); list_canvases lists them.")
            }
            studio.showCanvas(id)
        }
        let notes = arguments["notes"] as? [[String: Any]] ?? []
        let groups = arguments["groups"] as? [[String: Any]] ?? []
        let ungrouped = arguments["ungrouped"] as? [String] ?? []
        let arrows = arguments["arrows"] as? [[String: Any]] ?? []
        let pdfPages = arguments["pdf_pages"] as? [[String: Any]] ?? []
        let trees = arguments["trees"] as? [[String: Any]] ?? []
        let talks = arguments["talks"] as? [[String: Any]] ?? []
        guard notes.count <= 60, groups.count <= 20, arrows.count <= 100, pdfPages.count <= 10, trees.count <= 10, talks.count <= 5 else {
            throw MCPError.invalidInput("At most 60 notes, 20 groups, 100 arrows, 10 pdf_pages, 10 trees and 5 talks in one call.")
        }
        guard !(notes.isEmpty && passages.isEmpty && groups.isEmpty && ungrouped.isEmpty && pdfPages.isEmpty && trees.isEmpty && talks.isEmpty) else {
            throw MCPError.invalidInput("build_canvas needs notes, groups, trees, pdf_pages, talks or ungrouped cards to set down.")
        }
        // What a call gets wrong is refused before anything is written.
        for arrow in arrows {
            _ = try edgeRoute(arrow["route"])
            _ = try edgeHeads(arrow["heads"])
            _ = try edgeColor(arrow["color"])
            _ = try edgeStance(arrow["stance"])
        }
        let specs = try treeSpecs(from: trees)
        // A note is an Idea, whose own text holds its words: only the library's
        // cards and the passages quoted take an annotation.
        var annotationWords: [String: String] = [:]
        if let given = arguments["annotations"], !(given is NSNull) {
            guard let object = given as? [String: Any] else { throw MCPError.invalidInput("annotations is an object of note key or item_id to words.") }
            let noteKeys = Set(notes.compactMap { ($0["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                + specs.flatMap { $0.notes.compactMap(\.key) })
            for (key, raw) in object {
                let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let text = raw as? String else { throw MCPError.invalidInput("The annotation for \(name) is text.") }
                if noteKeys.contains(name) || name.hasPrefix("idea:") {
                    throw MCPError.invalidInput("An Idea's own note holds its words, so \(name) takes no annotation; give annotations to the library's cards and the passages quoted.")
                }
                if let cleaned = try cardAnnotation(text) { annotationWords[name] = cleaned }
            }
        }
        let (_, map) = try await preparedMap(opening: true)
        if map.lens != nil {
            throw MCPError.invalidInput("A lens shows on the Canvas: keep it (keep_map_lens) or clear it (clear_map_lens) first, as the learner's own edits wait for it.")
        }
        let notebookID = studio.openCanvas?.notebookID
        // The whole call is one step of Undo (unless a spoken request's group holds it already).
        let groupsEdits = !map.isEditGroupOpen
        if groupsEdits { map.beginEditGroup() }
        defer { if groupsEdits { map.endEditGroup() } }
        // Every await below may let the learner open another canvas: nothing more is written then.
        func stillOpen() throws {
            guard studio.knowledgeMap === map else {
                throw MCPError.invalidInput("Another canvas was opened while build_canvas was working, so it stopped; the Ideas it had made stay in the learner's Ideas.")
            }
        }

        // Write the notes as Ideas first, so the map knows them as cards.
        var keyed: [String: String] = [:]
        var made: [[String: Any]] = []
        for note in notes {
            let key = (note["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (note["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !title.isEmpty else { throw MCPError.invalidInput("Every note needs a key and a title.") }
            guard keyed[key] == nil else { throw MCPError.invalidInput("Two notes share the key \(key).") }
            let text = (note["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idea = await studio.createIdea(title: title, notes: text?.isEmpty == false ? text : nil) else {
                throw MCPError.invalidInput("The note \(key) could not be saved.")
            }
            if let notebookID { await studio.addIdea(idea.id, toNotebook: notebookID) }
            let ref = KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description
            keyed[key] = ref
            made.append(["key": key, "item_id": ref, "title": title])
        }
        // Mind maps: each tree's notes are Ideas too, written root first and
        // children in the order given, then laid out below once the map knows them.
        struct TreePlan {
            var name: String
            var color: String?
            var root: String
            var children: [String: [String]]
            var notes: [[String: Any]]
        }
        var treePlans: [TreePlan] = []
        for (index, spec) in specs.enumerated() {
            var refs: [String] = []
            var plan = TreePlan(name: spec.name, color: spec.color, root: "", children: [:], notes: [])
            for (position, note) in spec.notes.enumerated() {
                let key = note.key ?? "tree\(index + 1).\(position + 1)"
                guard keyed[key] == nil else { throw MCPError.invalidInput("Two notes share the key \(key).") }
                guard let idea = await studio.createIdea(title: note.title, notes: note.text) else {
                    throw MCPError.invalidInput("The note \(key) could not be saved.")
                }
                if let notebookID { await studio.addIdea(idea.id, toNotebook: notebookID) }
                let ref = KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description
                refs.append(ref)
                keyed[key] = ref
                var entry: [String: Any] = ["key": key, "item_id": ref, "title": note.title]
                if let parent = note.parent {
                    plan.children[refs[parent], default: []].append(ref)
                    entry["parent_item_id"] = refs[parent]
                } else {
                    plan.root = ref
                }
                plan.notes.append(entry)
            }
            treePlans.append(plan)
        }
        // Passages are cards in the highlight's own right: the map reads them
        // once told they were made for this canvas.
        for (key, highlightID) in passages.sorted(by: { $0.key < $1.key }) {
            guard keyed[key] == nil else { throw MCPError.invalidInput("Two notes share the key \(key).") }
            let ref = KnowledgeMap.ItemRef(kind: .clip, id: highlightID).description
            keyed[key] = ref
            map.pendingPassageIDs.insert(highlightID)
            made.append(["key": key, "item_id": ref, "kind": "passage"])
        }
        // Cards named by item_id may be ones made a moment ago.
        let named = groups.flatMap { $0["items"] as? [String] ?? [] } + ungrouped
            + arrows.flatMap { [$0["from"], $0["to"]].compactMap { $0 as? String } } + Array(annotationWords.keys)
        if !keyed.isEmpty {
            await studio.refreshKnowledgeMapContent()
        } else {
            await refreshUnknownKinds(named, in: studio)
        }
        try stillOpen()

        var unresolved: [String] = []
        func resolve(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref = keyed[trimmed] { return ref }
            if let ref = cardRefs([trimmed], in: map).known.first { return ref }
            unresolved.append(trimmed)
            return nil
        }
        // The words for the cards named, by ref: an Idea named by item_id is
        // refused as a note is. Read once the PDFs' pages and the talks' slides
        // are laid out, so their cards can be named too.
        var annotated: [String: String] = [:]
        func resolveAnnotations() {
            for (name, words) in annotationWords.sorted(by: { $0.key < $1.key }) {
                guard let ref = resolve(name) else { continue }
                if ref.hasPrefix("idea:") {
                    unresolved.append("annotation for \(name): an Idea's own note holds its words")
                } else {
                    annotated[ref] = words
                }
            }
        }
        var annotationsWritten = 0
        // Each block starts after the last one's right edge, level with its top.
        var next: KnowledgeMapArranging.Spot?
        func place(_ refs: [String], regionName: String?, color: String?) -> String? {
            let words = annotated.filter { refs.contains($0.key) }
            // The block is laid out for the room the words take under their cards.
            let heights = refs.map { map.heightWhenSetDown($0, annotation: words[$0]) }
            let block = KnowledgeMapArranging.block(heights: heights, origin: .init(x: 0, y: 0)).frame
            let center = next.map { KnowledgeMapArranging.Spot(x: $0.x + block.w / 2, y: $0.y + block.h / 2) } ?? map.arrivalCenter()
            let id = map.placeBlock(refs, near: center, regionName: regionName, color: color, annotations: words)
            annotationsWritten += words.count
            if let id, let region = map.layout.regions[id] {
                next = .init(x: region.x + region.w + 80, y: region.y)
            } else if let spot = refs.compactMap({ map.spot(of: $0) }).max(by: { $0.x < $1.x }) {
                next = .init(x: spot.x + KnowledgeMap.cardWidth + 80, y: refs.compactMap { map.spot(of: $0)?.y }.min() ?? spot.y)
            }
            return id
        }
        var regions: [[String: Any]] = []
        var placedRefs = Set<String>()
        // A PDF's pages: one card each, in a row of their own, set down first
        // so a group or an arrow can name them by item_id.
        var pdfResults: [[String: Any]] = []
        var pageFocus: [String] = []
        for entry in pdfPages {
            let raw = (entry["source_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { unresolved.append("pdf_pages entry without a source_id"); continue }
            do {
                let show = (entry["show"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "pages"
                guard let paperLayout = KnowledgeMapPaperLayout(rawValue: show) else {
                    throw MCPError.invalidInput("pdf_pages show must be pages, figures or figures_extended, not \"\(show)\".")
                }
                var done: [String: Any] = ["source_id": raw, "show": paperLayout.rawValue]
                let refs: [String]
                let regionID: String?
                switch paperLayout {
                case .pages:
                    let outcome = try await studio.layOutKnowledgeMapPages(
                        sourceID: raw,
                        pages: entry["pages"] as? String,
                        collapsed: entry["collapsed"] as? Bool ?? false,
                        color: try regionColor(entry["color"])
                    )
                    done["title"] = outcome.sourceTitle
                    done["page_count"] = outcome.pageCount
                    if !outcome.alreadyOn.isEmpty { done["already_on_canvas"] = outcome.alreadyOn }
                    if outcome.leftOut > 0 { done["left_out"] = outcome.leftOut }
                    refs = outcome.refs
                    regionID = outcome.regionID
                case .figures, .figuresExtended:
                    // Figures only: one clip card per figure, from the printed captions.
                    let outcome = try await studio.layOutKnowledgeMapFigures(
                        sourceID: raw,
                        includeExtended: paperLayout.includesExtended,
                        collapsed: entry["collapsed"] as? Bool ?? false,
                        color: try regionColor(entry["color"])
                    )
                    done["title"] = outcome.sourceTitle
                    done["figure_count"] = outcome.figureCount
                    if !outcome.alreadyOn.isEmpty { done["already_on_canvas"] = outcome.alreadyOn }
                    if outcome.extendedLeftOut > 0 { done["extended_left_out"] = outcome.extendedLeftOut }
                    refs = outcome.refs
                    regionID = outcome.regionID
                }
                try stillOpen()
                done["item_ids"] = refs
                if let regionID { done["region"] = regionEntry(regionID, in: map) }
                pdfResults.append(done)
                pageFocus += refs.prefix(3)
            } catch {
                unresolved.append("pdf_pages \(raw): \(error.localizedDescription)")
            }
        }
        // A talk's slides, as a storyboard with the papers each cites under it.
        var talkResults: [[String: Any]] = []
        for entry in talks {
            let raw = (entry["source_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { unresolved.append("talks entry without a source_id"); continue }
            do {
                let outcome = try await studio.layOutKnowledgeMapTalk(sourceID: raw)
                try stillOpen()
                var done: [String: Any] = [
                    "source_id": raw,
                    "title": outcome.sourceTitle,
                    "slide_item_ids": outcome.slides,
                    "paper_item_ids": outcome.papers,
                    "cited_papers_recorded": outcome.citedCount,
                    "cited_not_in_library": outcome.citedElsewhere,
                ]
                if let regionID = outcome.regionID {
                    done["region"] = regionEntry(regionID, in: map)
                } else {
                    // Laid out before: only papers new to the library were hung under their slides.
                    done["already_on_canvas"] = true
                }
                talkResults.append(done)
                pageFocus += outcome.slides.prefix(4)
            } catch {
                unresolved.append("talks \(raw): \(error.localizedDescription)")
            }
        }
        try stillOpen()
        resolveAnnotations()
        // Nothing the learner placed already moves: a card on the canvas stays
        // where it is (and still takes its annotation and arrows).
        var alreadyOn: [String] = []
        func toSetDown(_ refs: [String]) -> [String] {
            refs.filter { ref in
                guard placedRefs.insert(ref).inserted else { return false }
                guard map.layout.placements[ref] == nil else {
                    alreadyOn.append(ref)
                    return false
                }
                return true
            }
        }
        for group in groups {
            let name = (group["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { throw MCPError.invalidInput("Every group needs a name.") }
            let color = try regionColor(group["color"])
            let refs = toSetDown((group["items"] as? [String] ?? []).compactMap(resolve))
            guard !refs.isEmpty else { continue }
            if let id = place(refs, regionName: name, color: color) { regions.append(regionEntry(id, in: map)) }
        }
        let loose = toSetDown(ungrouped.compactMap(resolve))
        if !loose.isEmpty { _ = place(loose, regionName: nil, color: nil) }
        // Notes in no group or list still land on the canvas.
        let strays = made.compactMap { $0["item_id"] as? String }.filter { placedRefs.insert($0).inserted }
        if !strays.isEmpty { _ = place(strays, regionName: nil, color: nil) }

        // Mind maps, each in a region of its own: the notes laid out as a tree and
        // joined by branches, in the same left-to-right run as the groups.
        var treeResults: [[String: Any]] = []
        for plan in treePlans {
            // The map is laid out by what its notes say, as a mind map draws them.
            let titles = Dictionary(plan.notes.compactMap { note -> (String, String)? in
                guard let ref = note["item_id"] as? String, let title = note["title"] as? String else { return nil }
                return (ref, title)
            }, uniquingKeysWith: { first, _ in first })
            let size = map.treeFrameSize(root: plan.root, children: plan.children, titles: titles)
            let center = next.map { KnowledgeMapArranging.Spot(x: $0.x + size.w / 2, y: $0.y + size.h / 2) } ?? map.arrivalCenter()
            guard let placed = map.placeTree(root: plan.root, children: plan.children, near: center, regionName: plan.name, color: plan.color, titles: titles) else {
                unresolved.append("tree \(plan.name)")
                continue
            }
            if let region = map.layout.regions[placed.regionID] { next = .init(x: region.x + region.w + 80, y: region.y) }
            let refs = plan.notes.compactMap { $0["item_id"] as? String }
            placedRefs.formUnion(refs)
            treeResults.append([
                "region": regionEntry(placed.regionID, in: map),
                "root": plan.root,
                "notes": plan.notes,
                "branches": placed.edgeIDs.count,
            ])
        }

        var drawn: [[String: Any]] = []
        for arrow in arrows {
            func end(_ raw: Any?) -> String? {
                guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if text.hasPrefix(KnowledgeMap.regionRefPrefix) {
                    return (try? regionID(String(text.dropFirst(KnowledgeMap.regionRefPrefix.count)), in: map)).map(KnowledgeMap.regionRef)
                }
                return resolve(text)
            }
            guard let from = end(arrow["from"]), let to = end(arrow["to"]), from != to,
                  map.edgeRefusal(from: from, to: to) == nil,
                  let edgeID = map.addEdge(
                      from: from, to: to, label: arrow["label"] as? String,
                      route: try edgeRoute(arrow["route"]), dashed: arrow["dashed"] as? Bool,
                      heads: try edgeHeads(arrow["heads"]), color: try edgeColor(arrow["color"]),
                      stance: try edgeStance(arrow["stance"])
                  ) else {
                unresolved.append("arrow \(arrow["from"] ?? "?") → \(arrow["to"] ?? "?")")
                continue
            }
            drawn.append(["edge_id": edgeID, "from": from, "to": to, "label": map.layout.edges[edgeID]?.label ?? ""])
        }
        // Words for a card set down another way (a page of a PDF's row, a card on the Canvas already).
        let late = annotated.filter { ref, _ in (!placedRefs.contains(ref) || alreadyOn.contains(ref)) && map.layout.placements[ref] != nil }
        if !late.isEmpty {
            annotationsWritten += map.setPlacementStyle(late.map { KnowledgeMapPlacementStyle(ref: $0.key, annotation: .set($0.value)) })
            map.growRegions(toHold: Array(late.keys).sorted())
        }
        // Pages run far to the right, so a view of everything would shrink them
        // away: when there are other cards the view fits those.
        let setDown = placedRefs.subtracting(alreadyOn)
        map.send(.focus(refs: setDown.isEmpty ? pageFocus : Array(setDown), regionID: nil))
        var result: [String: Any] = ["notes": made, "regions": regions, "arrows": drawn, "cards_placed": setDown.count]
        if !alreadyOn.isEmpty { result["already_on_canvas"] = alreadyOn.map { card($0, in: map) } }
        if annotationsWritten > 0 { result["annotated"] = annotationsWritten }
        if !pdfResults.isEmpty { result["pdf_pages"] = pdfResults }
        if !talkResults.isEmpty { result["talks"] = talkResults }
        if !treeResults.isEmpty { result["trees"] = treeResults }
        if !unresolved.isEmpty { result["could_not_resolve"] = Array(unresolved.prefix(50)) }
        return result
    }

    /// Fetches the library again when a call names a card the Canvas has not
    /// read yet: an Idea, a source, a Doc, a chat, a canvas or a picture made
    /// a moment ago (the Canvas pane refreshes only while it is on screen). A
    /// page is a card only once placed, so it never asks.
    @MainActor
    static func refreshUnknownKinds(_ raw: [String], in studio: StudioViewModel) async {
        let wanted = raw.contains { id in
            guard let ref = KnowledgeMap.ItemRef(id.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ref.kind != .page else { return false }
            return studio.knowledgeMap.nodesByRef[ref.description] == nil
        }
        if wanted { await studio.refreshKnowledgeMapContent() }
    }

    /// lint_canvas: the open canvas's layout checked.
    @MainActor
    static func lintOpenCanvas(_ arguments: [String: Any]) async throws -> [String: Any] {
        let (_, map) = try await preparedMap(opening: false)
        return lintCanvas(arguments, map: map)
    }

    /// screenshot_canvas on the open canvas: a picture saved under Exports/
    /// in the library folder, and attached when small enough.
    func screenshotCanvas(arguments: [String: Any]) async -> MediaToolResult {
        do {
            return try await Self.screenshotOpenCanvas(arguments)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    @MainActor
    private static func screenshotOpenCanvas(_ arguments: [String: Any]) async throws -> MediaToolResult {
        let (studio, _) = try await preparedMap(opening: false)
        await refreshUnknownKinds(arguments["item_ids"] as? [String] ?? [], in: studio)
        return try await canvasScreenshot(
            arguments,
            map: studio.knowledgeMap,
            canvasName: studio.openCanvasName,
            isOnScreen: studio.knowledgeMapIsOnScreen,
            exportsFolder: URL(fileURLWithPath: StorageService.absoluteSourcePath("Exports"), isDirectory: true)
        )
    }

    @MainActor
    static func editCanvas(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let (studio, map) = try await preparedMap(opening: name != "set_canvas_display")
        // A card made a moment ago is a card once the library is read again.
        let annotationKeys = (arguments["annotations"] as? [String: Any]).map { Array($0.keys) } ?? []
        await refreshUnknownKinds(
            (arguments["item_ids"] as? [String] ?? []) + (arguments["grow_to_hold"] as? [String] ?? []) + annotationKeys
                + ["from", "to", "beside"].compactMap { arguments[$0] as? String },
            in: studio
        )
        guard studio.knowledgeMap === map else {
            throw MCPError.invalidInput("Another canvas was opened while \(name) was reading the library; nothing was changed.")
        }
        // One call is one step of Undo, however many writes it makes (a
        // spoken request's group, when one is open, holds it instead).
        let groupsEdits = name != "undo_canvas" && !map.isEditGroupOpen
        if groupsEdits { map.beginEditGroup() }
        defer { if groupsEdits { map.endEditGroup() } }
        // A notebook a call names, when the library has it (and it is a notebook, not a course).
        let notebookLookup: NotebookLookup = { id in
            studio.notebook(id: id).flatMap { $0.isNotebook ? ($0.id, NotebookTitle($0.title).text) : nil }
        }
        if map.lens != nil, !["keep_map_lens", "undo_canvas", "set_canvas_display"].contains(name) {
            throw MCPError.invalidInput("A lens shows on the Canvas: keep it (keep_map_lens) or clear it (clear_map_lens) first, as the learner's own edits wait for it.")
        }
        switch name {
        case "place_on_canvas":
            return try placeOnCanvas(arguments, map: map)

        case "take_off_canvas":
            let (refs, unknown) = cardRefs(arguments["item_ids"] as? [String] ?? [], in: map)
            let placed = refs.filter { map.layout.placements[$0] != nil }
            map.unplace(placed)
            var result: [String: Any] = [
                "taken_off": placed.map { card($0, in: map) },
                "not_on_canvas": refs.filter { !placed.contains($0) }.map { card($0, in: map) },
            ]
            if !unknown.isEmpty { result["not_in_library"] = Array(unknown.prefix(50)) }
            return result

        case "canvas_region":
            switch arguments["action"] as? String {
            case "create":
                return try createCanvasRegion(arguments, map: map, notebook: notebookLookup)
            case "update":
                return try updateCanvasRegion(arguments, map: map, notebook: notebookLookup)
            case "delete":
                let id = try regionID(arguments["region"], in: map)
                let entry = regionEntry(id, in: map)
                let takeOff = arguments["take_cards_off"] as? Bool ?? false
                let cards = takeOff ? map.refsInRegion(id) : []
                map.deleteRegion(id, takingCardsOff: takeOff)
                return ["deleted": entry, "cards_taken_off": cards.count]
            default:
                throw MCPError.invalidInput("canvas_region needs action create, update or delete.")
            }

        case "canvas_arrow":
            switch arguments["action"] as? String {
            case "draw": return try drawCanvasArrow(arguments, map: map)
            case "update": return try changeCanvasArrow(arguments, map: map, deleting: false)
            case "delete": return try changeCanvasArrow(arguments, map: map, deleting: true)
            default: throw MCPError.invalidInput("canvas_arrow needs action draw, update or delete.")
            }

        case "update_canvas_card":
            return try updateCanvasCard(arguments, map: map)

        case "arrange_on_canvas":
            return try arrangeOnCanvas(arguments, map: map)

        case "undo_canvas":
            let redo = arguments["redo"] as? Bool ?? false
            guard redo ? map.canRedo : map.canUndo else {
                throw MCPError.invalidInput(redo ? "Nothing on the Canvas has been undone to redo." : "No edit of the Canvas on this Mac to undo since ForeverLM opened.")
            }
            if redo { map.redo() } else { map.undo() }
            return [redo ? "redone" : "undone": true, "can_undo": map.canUndo, "can_redo": map.canRedo]

        case "keep_map_lens":
            guard let lens = map.lens else { throw MCPError.invalidInput("No lens shows on the Canvas.") }
            let cards = lens.positions.count, regions = lens.frames.count
            map.keepLens()
            return ["kept": true, "cards_placed": cards, "regions_drawn": regions]

        case "set_canvas_display":
            if let on = arguments["memory_layer"] as? Bool { map.memory.isShown = on }
            if let on = arguments["written_faces"] as? Bool { map.showsWrittenFaces = on }
            if let on = arguments["view_captions"] as? Bool { map.describesView = on }
            return ["memory_layer": map.memory.isShown, "written_faces": map.showsWrittenFaces, "view_captions": map.describesView]

        default:
            throw MCPError.invalidInput("Unknown Canvas tool \(name).")
        }
    }
}
#endif
