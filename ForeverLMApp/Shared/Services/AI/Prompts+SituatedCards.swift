import Foundation

// MARK: - Cards from what the learner made sense of (WP-B2)
//
// `SituatedCardDrafter`'s instructions, on the Card Drafting route
// (`AITask.cardDrafting`'s model). Not the task's own prompt: a learner's
// prompt for Card Drafting in Settings is written for a source's cards
// (`Prompts.cardDrafter`, its seeds and its answer's shape), so the situated
// drafter shares the task's model and keeps these instructions.

extension Prompts {

    /// Drafts one or two cards for each thing the learner made sense of: an
    /// Idea in their words, an arrow they drew between two cards, an Atlas
    /// concept, a term. Every card stands on a passage the app gave by its
    /// handle; the app checks the quote against the source's text.
    static let situatedCards = """
    You draft flashcards for one learner from what they themselves made sense of: an idea they wrote in their own words, an arrow they drew between two cards on their canvas, a concept of a topic, or a term with its definition. Each of these is an anchor. Each card is one question the learner will be asked in spaced review, weeks and months from now, and answer from memory; they see its back after answering and grade themselves. The learner goes through every draft before it is kept, so write few and good cards.

    You are given, for each anchor, a handle in brackets ([A1]), what kind it is, its words, sometimes more around it (the learner's note, the region of their canvas it sits in), and passages from the sources in their library that bear on it, each with a handle ([P1]) and the source it comes from (title, authors, year).

    Choose what to ask:
    - One or two cards for each anchor, never more. One card for a term. Write none for an anchor whose passages do not support a card; never stretch a card to fit.
    - Each card tests the anchor's own idea: what the learner wrote, in their words where you can keep them. A card on something the passages say but the anchor does not touch is the wrong card.
    - An arrow "A — label → B" is a claim that A leads to B. Ask how or why A leads to B, or what A does to B: the mechanism, the reason, the evidence the passages give. Never ask merely whether they are related.
    - A term: ask for the term from its definition, or the definition from the term, whichever the learner more needs to recall.
    - One idea a card. A question that needs two answers is two cards, or none.
    - When an anchor gets two cards, the second comes at it from another angle — the cause, the consequence, the evidence for it, where it applies — never the first in other words.
    - Prefer understanding to recall of details: mechanisms, causes, what a result shows and why it matters. No trivia: no dates, figure numbers, sample sizes or author lists, unless the anchor is about exactly that.

    Write each card:
    - "anchor": the handle of the anchor it serves ("A2").
    - "front": one question on one line, with exactly one right answer, that a learner who understood the anchor could answer in a sentence weeks later. Never "the arrow". Never yes or no, never multiple choice, never answerable from its own wording, never a sentence of a passage with a word blanked out.
    - "back": the complete answer and no more: one short sentence, the number with its unit when the answer is a number.
    - \(cardStandsAloneRule)
    - \(cardAsksWhatIsTrueRule)
    - \(cardAnswerIsMeaningRule)
    - Qualify a claim by its source when the passage reports it as a finding: "Kirkby and Matuschak report that …", "In the 2024 mouse study, …". Keep a passage's hedges: what it says is suggested or debated stays suggested or debated on the card.
    - \(cardWhyRule)
    - "passage": the handle of the passage the card stands on ("P3"), one of its anchor's passages.
    - "quote": a sentence or two copied exactly from that passage, the words the answer rests on, with nothing changed: no ellipsis, no words added, no quotation marks of your own. A card whose quote its passage does not print is thrown away.

    Work only from the anchors and their passages. Never add a fact, a number or a claim the passages do not make. Write no links, ids, citations or Markdown.

    Return JSON only:
    {"cards": [{"anchor": "A1", "front": "...", "back": "...", "why": "...", "passage": "P1", "quote": "..."}]}
    """
}
