// MCPToolRegistry: the review tool definitions: each tool's name, description and schema.
import Foundation

extension MCPToolRegistry {

    static var reviewToolDefs: [MCPToolDef] {
        [
            Self.draftCardsToolDef,
            MCPToolDef(
                name: "save_card_drafts",
                description: "Save flashcards you drafted from the learner's sources as cards for them to check in ForeverLM: they wait in Memory's To Check (a notebook's Studio shows its count on its Cards row) until the learner keeps, edits or skips each one, and only a kept card is ever reviewed. Each card names its source_id, as list_sources or a search returns it (an id the library does not hold refuses the whole call), and a quote: words copied exactly from that source's text (get_source_content), the passage the card stands on. A card whose quote the source does not print is not saved and is listed under not_grounded. A card is about an idea, and an idea is often printed in more than one source: when other sources of the library state what the card asks, name each in also_from with its own quote (at most 5; find_card_sources finds them), and the card stands on all of them, its source chips in To Check and in review showing each. A link whose source's text does not print its quote is left off, the card still saved, and listed under not_grounded_links. Write front as the question to ask, back as the complete answer and no more, and why as one line on why the back is right. Draft few cards a source: for a paper, a talk or a long article, one card first that asks the learner to tell its story (the question, how it was studied, what it found, what it means), its back a short paragraph, then only the two to four findings worth knowing on their own, such as a headline number or the key mechanism; never ten or fifteen small factoids. A card stands on its own: it is asked weeks later among cards from every source, so neither face may point at its source unnamed (\u{201C}this lecture\u{201D}, \u{201C}the paper\u{201D}, \u{201C}the speaker\u{201D}, \u{201C}the authors\u{201D}); ask about the subject itself, or name the source. Every card is checked for that before it is saved (a small background model call on the learner's Card Wording Check model): one that points at its source is reworded once and listed under reworded, or, when the rewording does not fix it, not saved and listed under not_standalone; when the check cannot run, the source's cards are not saved and sources_not_saved says why. Images are the default: when a relevant slide, paper figure, diagram or other durable ForeverLM picture materially supports recall, include it in front_images or back_images; omit imagery only when no useful picture is available. Each face takes up to four pictures; pass the exact Markdown image line returned by show_source_image, inspect_paper_figure or generate_image, or {target, alt}. Multiple images share a row in review. Local paths, web URLs, chat attachments and made-up image ids are refused. seed is optional: a short, stable key for what the card was drafted from (a walkthrough step, a highlight, a review-guide question), so the same seed is never drafted twice. A card whose seed or front its source's cards already hold is not saved again (already_drafted), whether it was kept or skipped. Pass kept_by_default true when the learner asked you for these cards; leave it false for cards you drafted unasked. Either way the learner keeps, edits or skips each one. A draft waits in To Check until it is kept or skipped; it never expires. Cards stay the learner's own: they never enter a team, whatever notebook they were made for. Returns each source's saved_card_ids and what was not saved, with why.",
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
                                    "back": ["type": "string", "description": "The complete answer, and no more. It may end with one interactive visualization when clicking or moving something teaches the answer better than words (a chart whose bars open to the items behind them): a fenced code block whose language is visualization, holding one self-contained HTML document written as a chat visualization is (inline script, style and SVG; no network). The review runs it under the words, so the words stay a complete answer without it."],
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
                description: "List the learner's Memory cards in ForeverLM. status to_check (the default) lists the cards waiting in Memory's To Check: drafts not yet kept or skipped (kind draft, offered until kept or skipped) each with card_id, source_id, source_title, front, back, why, optional front_images/back_images, quote, origin and kept_by_default; sources lists every source the card stands on, its own first, each with source_id, source_title and the quote it stands on there (a card often stands on several). status kept lists the kept cards, each with card_id, item_id, ask (the wording to ask: the learner's own rewording when there is one), back, why, optional images, source_ids, sources (each with its quote) and where its schedule stands (new, due, or scheduled with next_due_at). status all lists both. notebook_id narrows to one Notebook's cards (those on its sources) and source_id to the cards that stand on that source, whichever it is of theirs. With to_check or all, drafting says what Make Cards and draft_cards drafted lately for those sources: each run's state and, once done, the card ids it added, the cards it did not find in their source (not_grounded) and the sources it read as excerpts (sampled). Reads only: keep or skip cards with triage_cards.",
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
                description: "Go through the learner's cards to check, as Memory's To Check does, and only on the learner's word: each decision is theirs. action keep makes a card a Memory card, first asked the day after it is kept; keep with front, back, why, front_images or back_images keeps it with those changes (Edit, then Keep). Image arrays replace that face's pictures and [] removes them. also_from (draft cards only) chooses the other sources the card is kept on, replacing the ones it was drafted with: [] keeps it on its own source alone, and a list keeps it on each source named with its quote, copied word for word from that source's text (a source whose text does not print its quote refuses the keep). A kept card stands on those sources for good; changing them later means starting the card over. action skip drops a draft for good, so its seed is never drafted again. decisions name cards by the card_id list_cards returned; keep_source_ids and skip_source_ids keep or skip every card to check on those sources at once. Returns what was kept (with item_id), skipped, refused (with why) and not found (decided already, expired, or not a card to check), and how many cards still wait.",
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
                description: "Change one of the learner's kept cards, as Memory's All Cards does, and only on the learner's word. Every edit changes the card in place, its schedule and answers so far kept, on every device: front rewords it (the words it was kept with clear the rewording), back and why change its answer, and front_images or back_images replace that face's pictures ([] removes them). Only start_over true makes a new card: the old card is retired with its answers and a new card is kept on the same passages, first asked the next day, returned as card_id beside previous_card_id. always_ask true asks the card in its own words every time, never a rewording; false lets its wording vary again. retire true retires the card, never asked again, its answers kept; it takes no other change. Pass card_id (or item_id) as get_due_cards or list_cards status kept returns it. A card still in Memory's To Check (its card_id from list_cards) is edited too, without being kept or skipped: front, back, why, front_images and back_images change it where it waits, whether or not it is on screen, and the learner's Keep keeps it as it then reads (Skip drops it); start_over, always_ask and retire are for kept cards, and keeping or skipping it is triage_cards'. New words are checked first, as save_card_drafts checks a draft: words that point at the source unnamed (\u{201C}this lecture\u{201D}, \u{201C}the paper\u{201D}) are reworded once (the message says so), or the change is refused with the reason. Returns the card's card_id, item_id, ask and always_ask after the change.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "card_id": ["type": "string", "description": "A card_id from get_due_cards or list_cards status kept."],
                        "item_id": ["type": "string", "description": "The card's item_id, instead of card_id."],
                        "front": ["type": "string", "description": "The question in the learner's new words."],
                        "back": ["type": "string", "description": "A new answer: starts the card over. It may end with one interactive visualization when clicking or moving something teaches the answer better than words (a chart whose bars open to the items behind them): a fenced code block whose language is visualization, holding one self-contained HTML document written as a chat visualization is (inline script, style and SVG; no network). The review runs it under the words, so the words stay a complete answer without it."],
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
                description: "Approve or reject sources that ForeverLM discovered for a Learning Companion goal. Approved sources enter the daily quiz rotation; rejected sources are tombstoned and never suggested again. Use after daily_quiz, list_notebooks or list_goals surfaces pending suggestions.",
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
                        "show": ["type": "string", "description": "Optional podcast show or YouTube channel name (from list_shows), or a recurring meeting series' title or group_id (from list_meeting_groups); part of the name also works. Restricts the search to that show's episodes or that series' meetings."],
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
                        "show": ["type": "string", "description": "Optional podcast show or YouTube channel name (from list_shows), or a recurring meeting series' title or group_id (from list_meeting_groups); part of the name also works. Restricts the sweep to that show's episodes or that series' meetings."],
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
                        "show": ["type": "string", "description": "Podcast show or YouTube channel name, from list_shows, or a recurring meeting series' title or group_id, from list_meeting_groups; part of the name also works (\"Huberman\")."],
                        "author": ["type": "string", "description": "Text the author or byline contains: a paper's authors, an article's author, a meeting's presenter."],
                        "title_contains": ["type": "string", "description": "Text the title contains. A book or course is stored as one source per chapter or lecture, so this also matches the title of the book or course the source belongs to (\"Transformer\" lists that book's chapters)."],
                        "text": ["type": "string", "description": "Text any of title, author, show or channel, journal, or book/course/playlist contains — use it for a person who may be a guest in an episode title or an author of a paper (\"Martin Picard\")."],
                        "source_type": ["type": "string", "enum": StudioSourceType.searchFamilyNames, "description": "Optional. One family of sources."],
                        "include_archived": ["type": "boolean", "description": "Also list archived sources (default false)."],
                        "limit": ["type": "integer", "description": "Maximum sources to return (default 200, maximum 1000). The answer says when more matched."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "browse_library",
                description: "The Library page of the ForeverLM view an assistant shows inside its own window (Claude, Codex, ChatGPT); for that view, not for model use. Lists the visible library newest first as the Mac's Library does: a book or course once, under its own title, author and cover, rather than chapter by chapter, and every row with a small thumbnail as a JPEG data URL. notebook_id gives that view the same rich rows for one Notebook's own sources. Hidden sources remain readable and are returned separately for the view's Hidden Items fold. Answers JSON: total and items for visible rows, hidden_total and hidden_items for hidden rows. Each item has kind (source, book or course), id (the chapter a book opens at, for open_in_app with kind source), type, title, byline, words, added, is_hidden and thumbnail; grouped items also have group_id and source_ids. To read the library yourself, use filter_sources.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Text the title, author, show or channel, journal, or book or course title contains."],
                        "source_type": ["type": "string", "enum": StudioSourceType.searchFamilyNames, "description": "Optional. One family of sources."],
                        "notebook_id": ["type": "string", "description": "Optional Notebook ID from list_notebooks. Restricts the app view to that Notebook's own approved sources."],
                        "limit": ["type": "integer", "description": "Rows to return, books counted once (default 40, maximum 400)."],
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
        ]
    }
}
