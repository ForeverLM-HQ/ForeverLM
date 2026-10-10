import Foundation

// MARK: - Ask the Canvas and written faces (WP-B1, docs/sensemaking-design.md)
//
// `Prompts.canvasAsk` (Prompts+Sensemaking.swift) is the system prompt of
// every Ask; the three task texts below lead the user message, before the
// Canvas as JSON (`CanvasAskService.message`); the two newest, Summarize and
// Break Down, answer with one Idea and with a source's concepts. `mapFaces` is the system prompt
// of the written faces, sent by the Canvas Summaries route.

extension Prompts {

    static let canvasAskBridge = """
    Task: Bridge. The asked cards are c1, c2 and so on; the candidates s1, s2 and so on are sources from the learner's library that were not asked about. Choose up to 5 candidates that connect the asked cards: a paper that supplies the missing mechanism or measurement between two of them, explains why they agree or clash, or carries one card's idea into another card's field. Prefer an improbable but real connection, one a researcher would not find by searching the cards' own keywords, over the obvious next paper on the same topic; but every bridge must rest on what the candidate's passage actually says. Skip a candidate that only repeats a card. A candidate marked "on_canvas" is placed elsewhere on the Canvas already: offer it only when the link is striking. Fewer is better than weak; return an empty list when nothing truly bridges.

    For each: "candidate" (its s id); "why" (at most 14 words: what it supplies between which cards, in the learner's terms); "near" (the ids of the asked cards it bridges, two or more when it can); "cites" (the ids of the passages the why rests on).
    Return {"proposals": [{"candidate": "s3", "why": "…", "near": ["c1", "c4"], "cites": ["p2", "p9"]}]}
    """

    static let canvasAskConnect = """
    Task: Connect. Propose up to 6 arrows between the asked cards marked "on_canvas" (only those can be an arrow's ends): how one bears on another. An arrow runs from the card that acts, claims or measures to the card it bears on. For each: "from" and "to" (card ids); "label" (at most 4 plain words in the learner's register, read as from, label, to: "explains the drop in", "measures", "contradicts"); "relation" (exactly one of supports, contradicts, explains, causes, measures, extends, example, same_question); "why" (at most 16 words: the specific reason); "cites" (the ids of the passages it rests on). The pairs listed under "arrows" are joined already: never propose them, either way round. Prefer what a researcher would want to remember, a contradiction or a causal step, over a loose "is related to". Fewer is better than weak; return an empty list when the cards do not bear on each other.
    Return {"proposals": [{"from": "c1", "to": "c3", "label": "…", "relation": "explains", "why": "…", "cites": ["p1"]}]}
    """

    static let canvasAskGaps = """
    Task: Gaps. Name 2 to 4 research questions the asked cards leave open: a missing link between two of them, an assumption they rest on that nobody tested, a conflict between them to resolve, or a measurement nobody made. Each "question" has at most 25 words, ends with a question mark, and is specific enough to design an experiment or a literature search around, in the learner's terms. Never ask what the cards already answer, and never ask a question so broad it would fit any field. For each also give "why" (at most 16 words: what in the cards opens it), "near" (the ids of the cards it grows from) and "cites" (the ids of the passages that show the gap).
    Return {"proposals": [{"question": "…?", "why": "…", "near": ["c2", "c5"], "cites": ["p4"]}]}
    """

    static let canvasAskSummarize = """
    Task: Summarize. Sum the asked cards up as ONE Idea the learner could have written: what they say together, in the learner's own terms where they wrote any (their Ideas' sentences and region names). Give "title": one sentence of at most 120 characters that states the claim or the question the cards add up to, specific enough to disagree with, never a label like "Notes on mitochondria". Give "note": 3 to 5 sentences in plain words: what the cards agree on, where they differ or leave a gap, and what rests on which source (name a source by its title, never an id). A card marked "learner_highlight" is something the learner marked; lean on it. Add "cites": the ids of the passages the note rests on. Say "may" or "if" where a link is your inference and not something a passage says. Never invent a finding, number or source.
    Return {"proposals": [{"title": "…", "note": "…", "cites": ["p1", "p4"]}]}, exactly one proposal.
    """

    static let canvasAskBreakDown = """
    Task: Break Down. The one asked card is a source the learner is working through; "source_passages" are passages p1, p2 and so on, spread in order from its start to its end. Take the source apart into its 5 to 12 main concepts (the claims, mechanisms, methods, measurements or arguments a reader must hold to understand it), in the order a reader meets them. Each concept is a note the learner could write on a whiteboard: "id" (k1, k2, … in that order); "title" (at most 12 words, a claim or a named thing, specific: "PINK1 accumulates on depolarised mitochondria", never "Introduction" or "Background"); "note" (one sentence of at most 28 words saying what the source shows or argues about it, in plain words); "cites" (the ids of the passages it rests on). Then 4 to 14 "arrows" between concepts that bear on each other, from the one that acts, causes or explains to the one it bears on: "from" and "to" (concept ids), "label" (at most 4 plain words, read as from, label, to: "recruits", "is measured by", "contradicts"). Join concepts the source itself joins; do not join everything to everything, and never add a concept the passages do not support. Fewer, sharper concepts beat a long list; a short source may have fewer than 5.
    Return {"concepts": [{"id": "k1", "title": "…", "note": "…", "cites": ["p2"]}], "arrows": [{"from": "k1", "to": "k2", "label": "…"}]}
    """

    static let canvasAskSetAside = """
    "set_aside" lists what the learner set aside from earlier answers to this question. Never propose any of those again, and steer away from what made them unhelpful.
    """

    /// The written faces of source cards on the Canvas, sent by the Canvas
    /// Summaries route (`AITask.mapSummaries`), not the learner's prompt for it.
    static let mapFaces = """
    You write the faces of source cards on a researcher's Canvas, so each card can be read at three distances. For each source you get its id, title, type and byline, and either the start of its text ("text_start") or the ideas extracted from it ("ideas"). Write:
    - "far": at most 6 words naming what it is about, the way a researcher would label it on a whiteboard ("PINK1 senses mitochondrial depolarisation"). Not a shortened title, and never "A study of…".
    - "mid": one sentence of at most 22 words with its main finding or claim, specific: what was shown, in what system, in which direction. For a talk, book or essay, its central argument.
    - "near": 2 or 3 short lines of at most 14 words each, in this order where the text supports them: "Question: …", "Approach: …", "Finding: …".
    Write only what the given text supports, and keep gene, protein, drug and method names as written. When the text is too thin to tell the finding, let "mid" say what the source sets out to do, and give fewer "near" lines. Plain words, no hype.
    Return ONLY JSON: {"faces": [{"id": "s1", "far": "…", "mid": "…", "near": ["Question: …", "Approach: …", "Finding: …"]}]}, one entry per source, with the ids given.
    """
}
