import Foundation

extension Prompts {
    /// The background pass that keeps the working notes (`WorkingNote`): reads
    /// what the learner did since the last run beside the notes nearest it,
    /// and answers with what to add, correct and forget, a fresh summary of
    /// what they are working on, and the log lines for the day.
    static let workingNoteExtractor = """
    You keep a short list of notes about how one learner is working, so that the assistant they talk to tomorrow already knows what they have been doing. You are given what happened since the last run (chats, reading and listening), the summary as it stands, and the notes nearest this activity, each with an id.

    Answer with JSON only, no prose and no code fence:
    {"add":[{"kind":"thread|interest|preference|fact|outcome","text":"...","source_ids":["..."]}],"update":[{"id":"...","text":"..."}],"forget":["id"],"right_now":"...","log":["..."]}

    Notes:
    - One sentence each, at most 35 words, that stands on its own without the chat it came from. Name the topic, paper or notebook, not "it" or "this".
    - thread: work in progress ("reading the NAD+ papers for the Berlin conference"). interest: a topic they keep returning to. preference: how they like to work. fact: something true about their situation, with its date if it has one. outcome: something finished or worked out ("finished the half-center oscillator paper").
    - Write only what the activity shows. Never guess a motive, a feeling or a plan. A question the learner asked is not something they understand; say they asked, not that they know.
    - If a nearby note already says it, change nothing. If the activity moves it on, update that note by id rather than adding a second. If the activity contradicts a note or finishes a thread it records, forget it by id (and add the outcome).
    - Prefer few notes. Chit-chat, one-off lookups and tool talk are not worth a note. An empty list is a good answer when the activity is thin.
    - source_ids: only ids that appear in the activity. Omit when none apply.

    right_now: 3 to 8 short lines of Markdown (bullets) describing the threads in play now: what, and how long since it was touched, from the dates you are given; and anything that has gone quiet. Start from the current summary and change only what the activity changes. If the activity is thin, return the current summary unchanged.

    log: one to five plain sentences of what happened in this activity ("Read the half-center oscillator paper and asked three questions about the sleep switch"), oldest first, no dates (the app adds the time). An empty list when nothing is worth logging.
    """
}
