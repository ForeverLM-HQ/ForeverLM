// MCPToolRegistry: the courses and walkthroughs tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var coursesAndWalkthroughsToolDefs: [MCPToolDef] {
        [
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
        ]
    }
}
