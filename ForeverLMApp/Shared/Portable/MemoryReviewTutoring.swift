import Foundation

/// One cohort source packaged for the model: what it is, why it is here, and
/// everything already known about how the learner has handled it.
struct CohortSourceBrief: Equatable, Sendable {
    let source: CohortSource
    /// The compressed account of what the source says, from `source_review_guides`.
    let guide: String?
    /// The learner's own highlights, most recent first.
    let highlights: [String]
    /// The current understanding document, verbatim, including hand edits.
    let understanding: String?
    /// Whether that document differs from what the model last wrote.
    let understandingHasLearnerEdits: Bool
    /// Questions about this source that already worked for this learner. Shown
    /// as a standard to match, never as wording to reuse.
    let exemplarQuestions: [String]
    /// The source's active ideas: what the contour is graded against. Empty
    /// for a brief built outside a memory review.
    var ideas: [SourceIdea] = []
    /// Ideas the source carries that this review will *not* grade, because the
    /// learner has not met them yet: a source in the cohort only because a chat
    /// touched part of it keeps the rest here. Listed to the tutor as context
    /// it may use to judge an answer, never as something to ask or grade
    /// (docs/memory-design.md, "A chat is not the whole source").
    var contextIdeas: [SourceIdea] = []
    /// The ids of the ideas the learner's chats have engaged, as the day close
    /// recorded them. What splits `ideas` from `contextIdeas` for a source the
    /// review only holds because it was discussed.
    var discussedIdeaIDs: [String] = []
    /// How much of a review this source gets when the learner says nothing.
    var depth: MemoryReviewDepth = .standard

    /// Highlights are the learner's own signal about what mattered, so they are
    /// worth more per token than more of the guide — but a heavily annotated
    /// book would otherwise swamp the prompt.
    static let maxHighlights = 8
    static let maxGuideCharacters = 2_400
    static let maxUnderstandingCharacters = 4_000

    /// Which of a source's ideas this review may ask about, and which it
    /// carries only as context.
    ///
    /// A chat is enough to put a source into a review
    /// (`SourceConsumption.confidence`: a discussion is consumption whatever
    /// the reader recorded), and that is deliberate — what was talked about
    /// yesterday is yesterday's material. But a chat is rarely about the whole
    /// paper. On 2026-09-21 a paper the learner had spent under a minute with,
    /// and had raised one question about, entered the review as spine with
    /// eight ideas from end to end, and the contour graded them on all eight.
    ///
    /// So: when the chat is the only reason a source is here — no reading
    /// depth of its own — the review asks about exactly what the day close
    /// recorded that conversation engaging, and the rest is context. A source
    /// the learner actually read is unaffected, however much was also said
    /// about it in a chat: reading is evidence about the whole text.
    ///
    /// The fallback is always the old behaviour. A document written before
    /// schema 129 records no discussed ideas, and "nothing known" must not
    /// silently mean "nothing to ask" — a source that would be narrowed to
    /// nothing keeps all of its ideas.
    static func gradableIdeas(
        _ ideas: [SourceIdea],
        discussedIdeaIDs: [String],
        engagement: CohortEngagement,
        confidence: SourceConsumptionConfidence
    ) -> (gradable: [SourceIdea], context: [SourceIdea]) {
        guard isChatOnly(engagement: engagement, confidence: confidence) else { return (ideas, []) }
        let discussed = Set(discussedIdeaIDs)
        let gradable = ideas.filter { discussed.contains($0.id) }
        guard !gradable.isEmpty else { return (ideas, []) }
        return (gradable, ideas.filter { !discussed.contains($0.id) })
    }

    /// Whether a chat is the whole of why this source is reviewable: it was
    /// discussed, and the learner's own passage through it never reached the
    /// depth that would make it reviewable on its own
    /// (`SourceConsumption.substantialFraction`). An explicitly finished
    /// source is never chat-only, whatever its measured depth says.
    static func isChatOnly(engagement: CohortEngagement, confidence: SourceConsumptionConfidence) -> Bool {
        guard engagement.isChatDiscussed, confidence != .complete else { return false }
        return engagement.depth < SourceConsumption.substantialFraction
    }
}

/// The memory review's tutor, in one place for every client.
///
/// A review is the same conversation whether it runs in the Mac's chat, on the
/// iPhone, or in a voice session: the same conduct, the same briefing on the
/// day's record, the same grading contract, the same words back to the model
/// after a grade. Everything here is Foundation-only so the Mac, the phone, and
/// the web core compile it unchanged; a client that needs a different sentence
/// is a client that will drift, and the learner would feel the seam.
enum MemoryReviewTutoring {

    /// How long a review gets is the learner's daily budget, `MemoryReviewBudget`:
    /// set in Settings → Memory on either device, fifteen minutes by default,
    /// and passed into `briefing(...)` by whichever client plans the day.

    /// The in-app twin of the MCP conduct instructions, minus the tool call an
    /// external assistant ends with: here the session closes the way every
    /// review chat does.
    static let conductInstructions = """
    This chat is today's memory review over material the learner actually read, listened to, or watched. \
    A plan was made for you; work its moves in order and compose every question's wording yourself, live.

    Open with one or two sentences saying what today covers and why — draw on the planner's opening line — \
    then ask the first question of the first move. Do not show a checklist, do not summarize a source, and \
    do not read any of the material below out before the learner has attempted to recall it.

    `role` says what each source is for. `spine` is what the session is about: recently taken in, not yet \
    reviewed. `spacing` is due again. A `bridge` is present only to be put in friction with the spine \
    source it was drawn against; never review a bridge on its own.

    Ask one question at a time. Require production from memory before offering any hint.

    Ask only about what the learner actually met. A source says how far they got, and a source they \
    only discussed in a chat carries just the ideas that conversation touched; the rest is listed \
    under NOT YET MET, for context when you judge an answer and for nothing else. Never ask about \
    one, never mention that it exists, and never treat its absence as a gap in their memory — they \
    have not read it yet. When the contour is all they have met, say so in a clause as you close \
    the source rather than implying they forgot the rest.

    Every source opens with one CONTOUR: ask them to say what the source was about, in their own words, in a \
    sentence or three — unaided, before any help. When they answer, call `grade_memory_contour` for that \
    source with one entry per idea listed under it in the briefing (produced / partial / missing), an \
    overall score, and `question_verdict`: `ambiguous` when your wording, not their memory, is what the \
    answer misses. When nothing came back, every idea is missing and the score is 0.0, sent as a number. If the \
    grader rejects the call, its message says what arrived and what to fix; fix that one argument and call it \
    again with the same judgment, never a changed grade, and if it is rejected a second time tell the learner and \
    stop. Never mention or paraphrase an idea marked missing in your reply: feedback names what \
    came back and that something did not, and a missing idea stays missing until they retrieve it. Then \
    follow the source's DEPTH given in the briefing — quick stops after the graded reply; standard asks one \
    or two probes, chosen from the ideas marked missing or partial, wanted ideas first, then open threads in \
    their understanding document; deep works the planner's moves for that source.

    You never leave a source on your own. When its depth is spent — for quick, in the graded reply itself; \
    for standard, in the reply that answers its last probe; for deep, after its last move — close the source \
    in a clause and end your reply by asking, in one short line, whether they want to move on or stay on this \
    one a little longer. Then stop and wait: no new question, and no turn to another source in that reply. \
    From the graded reply on, the learner sees two chips under every reply, Next and Go deeper, and may also \
    type or say the words; Next is the only thing that takes you to the next source, Go deeper keeps you on \
    this one, and either overrides the depth for that source, with their steer recorded. Three Nexts in a row \
    on one kind of source makes that kind quick by default; you will be told when that happens, and you say \
    so once.

    A probe rotates the operation — recall, explain, contrast, apply, connect — so no idea is met twice in \
    the same shape, and it names nothing the contour grade marked missing. When the learner says "keep \
    podcasts quick", "go deep on this one", or the like, call `set_review_depth` and confirm in half a \
    sentence; a word undoes it. Depth never skips a contour.

    When a source's contour came back whole, Go deeper goes past recall into understanding: ForeverLM names, \
    beside the learner's words, ONE understanding probe on one of its ideas. The probes are \(MemoryUnderstandingProbe.kindsLine). \
    Ask that one probe (when none is named, the kind after the last one you asked, never an analogy without a \
    named partner), answer the learner's reply in two or three sentences — what it got, what it missed or \
    could add, no score, no flattery — without calling the grader (a source is graded once, at its contour), \
    and stop. A probe is never a gate: Next is always one word away.

    At least one question must span two sources from different times when the plan has a connect or \
    contrast move; a run of single-source recall questions is a failure.

    \(MemoryReviewSourceTurn.instruction)

    Do not end because the moves ran out. Continue until the learner says they are done. Before you close, \
    name anything that did not fit, and ask them once what they want brought back next time, in their own words.
    """

    /// The conduct for a review planned by topic (docs/memory-design.md,
    /// "Review by topic"): the unit is a topic whose ideas come from several
    /// sources, asked as one question and graded with `grade_topic_recall`.
    /// Used whenever the plan carries topics; `conductInstructions` stays for
    /// a review planned before them.
    static let topicConductInstructions = """
    This chat is today's memory review over material the learner actually read, listened to, watched, \
    or talked through. It is organized by TOPIC, not by source: each topic under TOPICS below is a handful \
    of ideas about one subject, drawn from whichever sources and chats carried them. Work the topics in \
    order and compose every question's wording yourself, live.

    Open with ONE short sentence naming today's topics in plain words (never a list of source titles), \
    then the first topic's turn line and its opening question. Do not show a checklist, do not summarize \
    a source, and do not read any of the material below out before the learner has attempted to recall it.

    Each topic opens with ONE question the learner can answer from anything they took in on the subject: \
    what they now understand about it, in their own words. Ask about the subject, never about a container — \
    never "what was the chat about" or "what did this paper say". Name enough of the subject that the \
    question stands on its own, heard as well as read, and never name or hint at the ideas you will grade. \
    A `connection` topic's question spans its two sides and asks how they meet.

    Ask one question at a time. Require production from memory before offering any hint. Ask only about \
    what the learner actually met: ideas listed under NOT YET MET are context for judging an answer and \
    nothing else, and a source read part of the way is asked about only as far as they got.

    When they answer a topic's opening question, call `grade_topic_recall` with the topic_id and one \
    idea_coverage entry for EVERY idea the topic lists (produced / partial / missing), crediting an idea \
    whichever source it came from, an overall score, and `question_verdict`: `ambiguous` when your wording, \
    not their memory, is what the answer misses. When nothing came back ("I don't remember"), every idea is \
    missing and the score is 0.0, sent as a number. If the grader rejects the call, its message says what \
    to fix; fix that one argument and call it again with the same judgment, and if it is rejected a second \
    time tell the learner and stop.

    Then reply in at most three sentences: what came back, and that something did not, without naming or \
    paraphrasing any idea graded missing. The learner sees each idea as a row on the card: what came back \
    in full, what came back in part, and a veiled row for the rest naming only the source it came from. \
    End there. Do not ask another question and do not move on: the learner chooses Go deeper or Next topic.

    On "Go deeper", while the topic has an idea graded missing or partial, ask ONE probe about one of them, \
    wanted ideas first, rotating the operation (recall, explain, contrast, apply, connect) so no idea is met \
    twice in the same shape; it names nothing graded missing. When they answer, call `grade_topic_recall` \
    again for the same topic with an entry for the probed idea alone (or the few it covered). If a probed \
    idea is missing again, re-teach it briefly from its source in your reply, naming where it came from; it \
    comes back tomorrow. Then stop and wait again.

    Once the topic has nothing missing or partial, Go deeper goes past recall into understanding. ForeverLM \
    names, beside the learner's words, ONE understanding probe, the idea it goes deeper on, and for an \
    analogy the nearby idea to set it beside. The probes are \(MemoryUnderstandingProbe.kindsLine). Ask \
    that one probe; when the learner asked in their own words and none is named, take the kind after the \
    last one you asked, never an analogy without a named partner. Grade the answer with \
    `grade_topic_recall` on the probed idea alone, with the probe's kind as `operation`: it says how deep \
    the understanding goes and never takes back that the idea came back. Reply in two or three sentences — \
    what the answer got, what it missed or could add, no score, no flattery — and stop and wait. A probe \
    is never a gate: Next topic is always one press away.

    On "Next" (or "Next topic"), write the next topic's turn line and ask its opening question. Never move \
    to another topic on your own.

    \(MemoryReviewSourceTurn.topicInstruction)

    After the last topic, when the learner says Next, close: in two or three sentences say what came back \
    and what did not fit today, then ask once what they want brought back tomorrow, in their own words. \
    Do not end before that because the topics ran out; continue until they say they are done.
    """

    /// How many topics a review of this length is planned with, before the
    /// connection: about three minutes a topic, the last three minutes left for
    /// the connection. Fifteen minutes is four topics and a connection.
    static func topicCount(budgetMinutes: Int) -> Int {
        let minutes = MemoryReviewBudget.clamp(budgetMinutes)
        return min(12, max(2, minutes / MemoryReviewBudget.minutesPerSource - 1))
    }

    // MARK: - Briefing

    /// The stable briefing the tutor carries for a memory review: how to
    /// conduct it, the plan, and the material. Persisted on the day's session
    /// record, so every client reopens onto the same plan and ideas, and no
    /// question text is ever stored.
    static func briefing(
        cohort: LearningCohort,
        briefs: [CohortSourceBrief],
        plan: CohortSessionPlan,
        skippedSources: [String] = [],
        startedAt: Date? = nil,
        budgetMinutes: Int = MemoryReviewBudget.defaultMinutes
    ) -> String {
        var lines: [String] = []
        lines.append("TODAY'S MEMORY REVIEW")
        lines.append("")
        lines.append(plan.topics.isEmpty ? conductInstructions : topicConductInstructions)
        lines.append("")
        lines.append(TutorContract.questionQualityInstructions)
        lines.append("")
        if let startedAt {
            lines.append(
                "TIME BUDGET: about \(MemoryReviewBudget.label(budgetMinutes)) from \(startedAt.formatted(date: .omitted, time: .shortened)), "
                + "the learner's own daily setting, unless they change it today. Today's material was chosen to fit it. "
                + (plan.topics.isEmpty
                    ? "Breadth first: every source gets its contour before any source gets depth. "
                    : "Breadth first: every topic gets its opening question before any topic gets depth. ")
                + "Name what did not fit when you close; never swallow it."
            )
            lines.append("")
        }
        if !skippedSources.isEmpty {
            lines.append("NOT REVIEWABLE TODAY (no ideas could be extracted; say so in one clause when you close):")
            for skipped in skippedSources { lines.append("- \(skipped)") }
            lines.append("")
        }
        if cohort.isBacklogOnly {
            lines.append(
                "NOTHING WAS DUE TODAY. Say so in one sentence, then offer the material below, "
                + "which is what has gone longest without being discussed."
            )
            lines.append("")
        }
        if cohort.droppedSpine > 0 || cohort.droppedSpacing > 0 {
            lines.append(
                "NOT INCLUDED TODAY: \(cohort.droppedSpine) further new source(s) and "
                + "\(cohort.droppedSpacing) further due source(s) did not fit. Say so when you close."
            )
            lines.append("")
        }
        lines.append(contentsOf: ledgerLines(cohort: cohort))
        lines.append("PLANNER'S OPENING LINE: \(plan.opening)")
        lines.append("")
        lines.append(movesHeading)
        for (index, move) in plan.moves.enumerated() {
            let ids = move.sourceIDs.map { "[\($0)]" }.joined(separator: " ")
            lines.append("\(index + 1). \(move.kind.rawValue) \(ids) — \(move.intent)")
        }
        lines.append("")
        if !plan.topics.isEmpty {
            lines.append(contentsOf: topicLines(plan.topics, briefs: briefs))
            lines.append("")
        }
        lines.append("SOURCES")
        lines.append("")
        for brief in briefs {
            lines.append(render(brief: brief))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Topics

    /// The line that opens the briefing's topic list.
    static let topicsHeading = "TOPICS, in order (ask each as one opening question; grade answers with grade_topic_recall):"
    static let topicLinePrefix = "TOPIC ["
    static let topicIntentPrefix = "Push on: "

    /// The topic list as the tutor reads it and a resume parses it back:
    /// `TOPIC [topic-1] new — Title`, the intent, then one `- [idea id]` line
    /// per cued idea with its statement and the source it came from.
    static func topicLines(_ topics: [MemoryReviewTopic], briefs: [CohortSourceBrief]) -> [String] {
        var ideas: [String: SourceIdea] = [:]
        var titles: [String: String] = [:]
        for brief in briefs {
            titles[brief.source.sourceID] = brief.source.title
            for idea in brief.ideas { ideas[idea.id] = idea }
        }
        var lines = [topicsHeading]
        for topic in topics {
            lines.append("\(topicLinePrefix)\(topic.id)] \(topic.kind.rawValue) — \(topic.title)")
            if !topic.intent.isEmpty { lines.append("\(topicIntentPrefix)\(topic.intent)") }
            for ideaID in topic.ideaIDs {
                var line = "- [\(ideaID)]"
                if let idea = ideas[ideaID] {
                    line += " \(idea.statement)"
                    if idea.wanted { line += " (THEY HIGHLIGHTED THIS)" }
                }
                if let sourceID = SourceIdea.sourceID(fromIdeaID: ideaID), let title = titles[sourceID] {
                    line += " (from \(title))"
                }
                lines.append(line)
            }
        }
        return lines
    }

    /// The topics a briefing carries, parsed back from its topic list, less
    /// every idea of a source the learner took out of the day; a topic left
    /// with no ideas goes. Empty for a briefing planned before topics.
    static func topics(inBriefing briefing: String?) -> [MemoryReviewTopic] {
        guard let briefing, briefing.contains(topicsHeading) else { return [] }
        let removed = Set(removedSourceIDs(inBriefing: briefing))
        var topics: [MemoryReviewTopic] = []
        var current: (id: String, title: String, kind: MemoryReviewTopicKind, intent: String, ideas: [String])?
        var inTopics = false

        func flush() {
            guard let topic = current else { return }
            current = nil
            let ideas = topic.ideas.filter { id in
                guard let source = SourceIdea.sourceID(fromIdeaID: id) else { return false }
                return !removed.contains(source)
            }
            guard !ideas.isEmpty else { return }
            topics.append(MemoryReviewTopic(id: topic.id, title: topic.title, kind: topic.kind, ideaIDs: ideas, intent: topic.intent))
        }

        for raw in briefing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == topicsHeading { inTopics = true; continue }
            guard inTopics else { continue }
            if line.hasPrefix(topicLinePrefix), let close = line.firstIndex(of: "]") {
                flush()
                let id = String(line[line.index(line.startIndex, offsetBy: topicLinePrefix.count)..<close])
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                var kind = MemoryReviewTopicKind.new
                var title = rest
                if let dash = rest.range(of: " — ") {
                    kind = MemoryReviewTopicKind(rawValue: String(rest[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)) ?? .new
                    title = String(rest[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                guard !id.isEmpty else { continue }
                current = (id, title, kind, "", [])
            } else if line.hasPrefix(topicIntentPrefix), current != nil {
                current?.intent = String(line.dropFirst(topicIntentPrefix.count))
            } else if line.hasPrefix("- ["), let close = line.firstIndex(of: "]"), current != nil {
                let id = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
                if !id.isEmpty, current?.ideas.contains(id) == false { current?.ideas.append(id) }
            } else if line.isEmpty {
                continue
            } else {
                // SOURCES, or any other heading, closes the list.
                break
            }
        }
        flush()
        return topics
    }

    /// What the planner is shown: the cohort, brief by brief, and the recent
    /// sessions it should not repeat.
    static func plannerUserMessage(
        cohort: LearningCohort,
        briefs: [CohortSourceBrief],
        recentSessionSummaries: [String],
        budgetMinutes: Int = MemoryReviewBudget.defaultMinutes
    ) -> String {
        var lines: [String] = []
        lines.append("TODAY'S COHORT (window: last \(cohort.windowDays) days)")
        lines.append("")

        for brief in briefs {
            lines.append(render(brief: brief))
            lines.append("")
        }

        if !recentSessionSummaries.isEmpty {
            lines.append("RECENT SESSIONS (most recent first)")
            for summary in recentSessionSummaries {
                lines.append("- \(summary)")
            }
            lines.append("")
        }

        if cohort.droppedSpine > 0 || cohort.droppedSpacing > 0 {
            // Told to the model so it can say so, rather than implying the
            // cohort was everything outstanding.
            lines.append(
                "NOT INCLUDED TODAY: \(cohort.droppedSpine) further new source(s) and "
                + "\(cohort.droppedSpacing) further due source(s) did not fit."
            )
            lines.append("")
        }
        lines.append(contentsOf: ledgerLines(cohort: cohort))

        let count = topicCount(budgetMinutes: budgetMinutes)
        lines.append(
            "TOPICS TO PLAN: \(count) topics for a \(MemoryReviewBudget.label(budgetMinutes)) review, "
            + "then one connection when there is material for it. Fewer when the ideas do not support that many."
        )
        lines.append("")
        lines.append("""
        Return JSON only:
        {"opening": "...", "topics": [{"title": "...", "kind": "new|due|weak|connection", \
        "idea_ids": ["..."], "intent": "..."}]}
        """)
        return lines.joined(separator: "\n")
    }

    /// The day as the ledger recorded it, and what was opened but is not
    /// being quizzed. Said to the planner and the tutor alike, so the review
    /// can be checked against the learner's own memory of the day.
    static func ledgerLines(cohort: LearningCohort) -> [String] {
        var lines: [String] = []
        if let ledger = cohort.ledger, !ledger.isEmpty {
            lines.append("THE DAY'S LEDGER — \(ledger.line()). Open by naming it in one clause.")
            lines.append("")
        }
        if !cohort.touched.isEmpty {
            lines.append(
                "ALSO OPENED, NOT REVIEWED (too little time or depth to quiz; you may name these in one clause, never ask about them):"
            )
            for touched in cohort.touched {
                let time = MemoryReviewLedger.durationLabel(seconds: touched.engagedSeconds)
                let depth = Int((touched.depth * 100).rounded())
                lines.append("- \(touched.title) (\(touched.sourceType); \(time), \(depth)% in)")
            }
            lines.append("")
        }
        return lines
    }

    /// The ids of the sources a briefing carries, in the order it lists them:
    /// the `### [id]` headers `render(brief:)` writes, once each. A record from
    /// before build 94 kept only its article ids, so a chat reviewed as material
    /// was lost from the record while the briefing still told the tutor to ask
    /// about it; a resume reads those ids back off the briefing it kept.
    static func sourceIDs(inBriefing briefing: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for line in briefing.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("### ["), let close = line.firstIndex(of: "]") else { continue }
            let id = String(line[line.index(line.startIndex, offsetBy: 5)..<close])
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// The line that opens the plan's move list in a briefing.
    static let movesHeading = "MOVES, in order:"

    /// The heading above the ideas the contour is graded against.
    static let ideasHeading = "IDEAS (grade the contour against these; use the ids exactly):"

    /// The heading above the ideas this review carries but will not ask about.
    /// They are listed by statement and never by id, so a model that reaches
    /// for one cannot name it in a grade and the grader would refuse it anyway.
    static let contextIdeasHeading =
        "NOT YET MET — the rest of this source, for context only. Do not ask about these, "
        + "do not grade them, and do not hold their absence against the learner:"

    /// How far into the source the learner actually got, when a position was
    /// measured. Said plainly, because the tutor otherwise treats every
    /// reviewable source as one that was finished — the 2026-09-21 review
    /// graded a paper read to 79% against ideas from its last sections.
    /// Nothing is said when nothing was measured; 0 is unmeasured, not a
    /// claim that they read none of it.
    static func depthLine(engagement: CohortEngagement) -> String? {
        let depth = engagement.depth
        guard depth > 0, depth < SourceConsumption.completeFraction else { return nil }
        return "GOT \(Int((depth * 100).rounded()))% OF THE WAY IN — ask only about the part they reached."
    }

    /// The idea ids a briefing lists as gradable: the `- [id]` lines under
    /// `ideasHeading`. A resume rebuilds the review's gradable set from these
    /// rather than from every idea the source has, so a source narrowed to
    /// what a chat touched stays narrowed when the review is reopened
    /// (`ReviewSessionManager.resumeSession`).
    static func gradableIdeaIDs(inBriefing briefing: String) -> Set<String> {
        var ids = Set<String>()
        var inIdeas = false
        for raw in briefing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == ideasHeading { inIdeas = true; continue }
            guard inIdeas else { continue }
            guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else {
                // Any other line closes the list: the next source's header, the
                // context ideas, the guide, a blank line.
                inIdeas = false
                continue
            }
            let id = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
            if !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    /// The sources the review is on before the tutor has written a single
    /// turn line or graded anything: those the first move still in play names.
    /// A move is out of play once every source it names has been removed by
    /// the learner. The opening request asks for "the first source's contour",
    /// so until a turn line or a grade says otherwise, the open question is
    /// about one of these ids. Empty when the briefing has no moves left.
    static func openingMoveSourceIDs(inBriefing briefing: String) -> [String] {
        let removed = Set(removedSourceIDs(inBriefing: briefing))
        for ids in moveSourceIDs(inBriefing: briefing) {
            let live = ids.filter { !removed.contains($0) }
            if !live.isEmpty { return live }
        }
        return []
    }

    /// The source ids each move names, move by move, in plan order; a move
    /// naming none is left out.
    static func moveSourceIDs(inBriefing briefing: String) -> [[String]] {
        var moves: [[String]] = []
        var inMoves = false
        for raw in briefing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == movesHeading { inMoves = true; continue }
            guard inMoves else { continue }
            // The move list ends at the first line that is not a numbered move.
            guard let dot = line.firstIndex(of: "."),
                  Int(line[..<dot]) != nil else {
                if line.isEmpty { continue }
                break
            }
            // "1. recall [id-a] [id-b] — intent": ids sit between the kind and
            // the intent dash; the intent may itself mention brackets.
            var head = Substring(line[line.index(after: dot)...])
            if let dash = head.range(of: " — ") { head = head[..<dash.lowerBound] }
            var ids: [String] = []
            var rest = head
            while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                let id = String(rest[rest.index(after: open)..<close])
                if !id.isEmpty, !ids.contains(id) { ids.append(id) }
                rest = rest[rest.index(after: close)...]
            }
            if !ids.isEmpty { moves.append(ids) }
        }
        return moves
    }

    /// The day's sources in the order the tutor will take them: first as the
    /// plan's moves name them, then the ones no move names, in their given
    /// order. What the chat's source strip shows, so its next chip is the
    /// review's next source rather than the selector's ranking
    /// (2026-09-22, when the strip led with two book chapters while the
    /// review opened on a chat).
    static func planOrdered(_ sourceIDs: [String], inBriefing briefing: String?) -> [String] {
        let given = Set(sourceIDs)
        var ordered: [String] = []
        var seen = Set<String>()
        for id in (briefing.map(moveSourceIDs) ?? []).joined()
        where given.contains(id) && seen.insert(id).inserted {
            ordered.append(id)
        }
        for id in sourceIDs where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    /// The title each `### [id] Title — role` header gives its source. The
    /// chat's source strip names a chat from here: a chat is review material
    /// without being a source row, so no article carries its title.
    static func sourceTitles(inBriefing briefing: String) -> [String: String] {
        var titles: [String: String] = [:]
        for raw in briefing.split(separator: "\n", omittingEmptySubsequences: true) {
            guard raw.hasPrefix("### ["), let close = raw.firstIndex(of: "]") else { continue }
            let id = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<close])
            guard !id.isEmpty, titles[id] == nil,
                  let title = headerTitle(afterID: raw[raw.index(after: close)...]) else { continue }
            titles[id] = title
        }
        return titles
    }

    /// "Title — role (drawn against x)" to "Title": the title is what sits
    /// before the last " — ".
    private static func headerTitle(afterID rest: Substring) -> String? {
        var title = String(rest).trimmingCharacters(in: .whitespaces)
        if let dash = title.range(of: " — ", options: .backwards) {
            title = String(title[..<dash.lowerBound])
        }
        return title.isEmpty ? nil : title
    }

    /// The heading under which a briefing lists the sources the learner took
    /// out of the day. The tutor reads it as an instruction; a resume reads
    /// the `REMOVED [id]` lines under it as a record, so the source stays out
    /// on every device without a second column anywhere.
    static let removedSourcesHeading =
        "REMOVED FROM TODAY'S REVIEW by the learner. Never ask about these, skip any move that names one, "
        + "and leave them out when you name what did not fit:"
    static let removedSourceLinePrefix = "REMOVED ["

    /// The ids a briefing records as removed by the learner, once each, in
    /// the order they were removed.
    static func removedSourceIDs(inBriefing briefing: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for line in briefing.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix(removedSourceLinePrefix), let close = line.firstIndex(of: "]") else { continue }
            let start = line.index(line.startIndex, offsetBy: removedSourceLinePrefix.count)
            guard start < close else { continue }
            let id = String(line[start..<close])
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// The briefing with one source taken out of the day. Its `### [id]`
    /// section goes, so the tutor no longer holds its ideas, and a
    /// `REMOVED [id] title` line is recorded under `removedSourcesHeading`,
    /// so the moves that still name it are skipped and a resume leaves it
    /// out (`ReviewSessionManager.memoryReviewMaterialSourceIDs`). A source
    /// the briefing never listed is only recorded; one already recorded
    /// changes nothing. The title falls back to the one its header carried.
    static func briefing(_ briefing: String, removingSource sourceID: String, title: String? = nil) -> String {
        let trimmedID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return briefing }
        if removedSourceIDs(inBriefing: briefing).contains(trimmedID) { return briefing }

        let header = "### [\(trimmedID)]"
        var kept: [String] = []
        var headerTitle: String?
        var skipping = false
        for line in briefing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("### [") || line == removedSourcesHeading || line.hasPrefix(removedSourceLinePrefix) {
                skipping = line == header || line.hasPrefix(header + " ")
                if skipping {
                    headerTitle = Self.headerTitle(afterID: line.dropFirst(header.count))
                }
            }
            if !skipping { kept.append(line) }
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        if !kept.contains(removedSourcesHeading) {
            kept.append("")
            kept.append(removedSourcesHeading)
        }
        let recordedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? headerTitle
            ?? trimmedID
        kept.append("\(removedSourceLinePrefix)\(trimmedID)] \(recordedTitle)")
        kept.append("")
        return kept.joined(separator: "\n")
    }

    static func render(brief: CohortSourceBrief) -> String {
        var lines: [String] = []
        let source = brief.source
        var header = "### [\(source.sourceID)] \(source.title) — \(source.role.rawValue)"
        if let bridgeTo = source.bridgeTo {
            header += " (drawn against \(bridgeTo))"
        }
        lines.append(header)
        lines.append("Type: \(source.sourceType). \(source.reason)")
        if source.sourceType == ReviewableChat.sourceType {
            lines.append(ReviewableChat.tutorNote)
        }
        if source.confidence == .partial {
            lines.append("PARTIAL READ — ask only about the part they reached.")
        }
        if let reached = depthLine(engagement: source.engagement) {
            lines.append(reached)
        }
        if !brief.ideas.isEmpty {
            lines.append("Depth when they say nothing — \(brief.depth.tutorInstruction).")
            lines.append(ideasHeading)
            for idea in brief.ideas {
                var line = "- [\(idea.id)] \(idea.statement)"
                if idea.wanted { line += " (THEY HIGHLIGHTED THIS)" }
                if !idea.recallNote.isEmpty { line += " — a good recall has: \(idea.recallNote)" }
                lines.append(line)
            }
        }
        if !brief.contextIdeas.isEmpty {
            lines.append(contextIdeasHeading)
            for idea in brief.contextIdeas {
                lines.append("- \(idea.statement)")
            }
        }

        if let guide = brief.guide, !guide.isEmpty {
            lines.append("What it says: \(String(guide.prefix(CohortSourceBrief.maxGuideCharacters)))")
        }
        if !brief.highlights.isEmpty {
            lines.append("Their highlights:")
            for highlight in brief.highlights.prefix(CohortSourceBrief.maxHighlights) {
                lines.append("- \(highlight)")
            }
        }
        if let understanding = brief.understanding, !understanding.isEmpty {
            let label = brief.understandingHasLearnerEdits
                ? "What they have made of it (contains their own hand edits — trust those):"
                : "What they have made of it:"
            lines.append(label)
            lines.append(String(understanding.prefix(CohortSourceBrief.maxUnderstandingCharacters)))
        }
        if !brief.exemplarQuestions.isEmpty {
            lines.append("Questions that worked before on this source (match the grain, not the wording):")
            for question in brief.exemplarQuestions {
                lines.append("- \(question)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - System prompt

    /// The system prompt a memory review turn runs under, for a client that
    /// has no other sources or tools attached: the review tutor, the answer
    /// language and id rules, the day's briefing, and the response budget — the
    /// same stable head the Mac's session manager composes, so a turn on the
    /// phone reads exactly like a turn on the Mac. The clock is the volatile tail.
    static func systemPrompt(
        briefing: String,
        localClockDescription: String
    ) -> String {
        var stable = Prompts.reviewTutor
        stable += Prompts.responseLanguage
        stable += Prompts.hiddenIDs
        stable += """

        Daily review focus for this session:
        \(briefing)
        """
        stable += """

        Response budget: finish every visible chat answer in a single bounded response. Prefer short paragraphs and compact sections over exhaustive dumps. If the learner asks for a very large artifact, produce the useful edited artifact as compact Markdown rather than streaming raw notes or repeated source text.
        """
        return stable + """


        Local date and time: \(localClockDescription)
        """
    }

    // MARK: - Tools

    /// The grader the tutor calls after a contour recall. One definition, so
    /// the Mac's tool call and the phone's structured grading step ask for
    /// the same fields in the same words.
    static let gradeMemoryContourTool = TutorToolDefinition(
        name: "grade_memory_contour",
        description: "Privately grade the learner's contour recall of one review source before replying. Send the source_id and, for EVERY idea listed under that source in the briefing, an idea_coverage entry with the exact idea_id and a status: produced (came back unaided), partial (the shape without the substance), or missing. Add an overall score from 0.0 to 1.0, and question_verdict \"ambiguous\" when your wording rather than their memory is what the answer misses; it defaults to sound. Never invent an idea id. Call it once per contour, after the learner has answered, and then reply without reading out any missing idea.",
        parameters: .object([
            "source_id": .string("The review source whose contour was just answered."),
            "idea_coverage": .array(
                .object([
                    "idea_id": .string("An idea id from the briefing, exactly."),
                    "status": .string("produced, partial, or missing.", allowed: MemoryIdeaCoverage.Status.allCases.map(\.rawValue)),
                ], required: ["idea_id", "status"]),
                description: "One entry per idea of the source, in any order."
            ),
            "score": .number("Overall recall quality from 0.0 to 1.0."),
            "question_verdict": .string(
                "ambiguous blames the question: the answer is graded on the idea and no schedule moves.",
                allowed: [MemoryQuestionVerdict.sound.rawValue, MemoryQuestionVerdict.ambiguous.rawValue]
            ),
            "operation": .string(
                "The operation the question asked for; a contour is recall.",
                allowed: MemoryQuestionOperation.recallCases.map(\.rawValue)
            ),
            "evaluation": .string("One or two private sentences on what came back and what did not."),
        ], required: ["source_id", "idea_coverage", "score"])
    )

    /// The grader for a review planned by topic: the opening answer to a
    /// topic grades every idea it lists, across its sources; each Go deeper
    /// answer grades the probed idea alone, an understanding probe's with its
    /// kind as the operation.
    static let gradeTopicRecallTool = TutorToolDefinition(
        name: "grade_topic_recall",
        description: "Privately grade the learner's answer on one topic of today's review before replying. Send the topic_id and idea_coverage entries with the exact idea_id and a status: produced (came back unaided), partial (the shape without the substance), or missing. For the topic's opening question, grade EVERY idea the topic lists, whichever source it came from; for a Go deeper probe, grade only the idea or ideas the probe asked about, and for an understanding probe (principle, transfer, falsify, analogy) the probed idea alone with the probe's kind as operation. Add an overall score from 0.0 to 1.0, and question_verdict \"ambiguous\" when your wording rather than their memory is what the answer misses; it defaults to sound. Never invent an idea id. Then reply without reading out any missing idea.",
        parameters: .object([
            "topic_id": .string("The topic just answered, as the briefing lists it (topic-1, topic-2, …)."),
            "idea_coverage": .array(
                .object([
                    "idea_id": .string("An idea id listed under that topic, exactly."),
                    "status": .string("produced, partial, or missing.", allowed: MemoryIdeaCoverage.Status.allCases.map(\.rawValue)),
                ], required: ["idea_id", "status"]),
                description: "The opening answer: one entry per idea of the topic. A probe: the probed idea."
            ),
            "score": .number("Overall recall quality from 0.0 to 1.0."),
            "question_verdict": .string(
                "ambiguous blames the question: the answer is graded on the idea and no schedule moves.",
                allowed: [MemoryQuestionVerdict.sound.rawValue, MemoryQuestionVerdict.ambiguous.rawValue]
            ),
            "operation": .string(
                "The operation the question asked for; an opening question is recall, a connection's is connect, an understanding probe's is its kind.",
                allowed: MemoryQuestionOperation.allCases.map(\.rawValue)
            ),
            "evaluation": .string("One or two private sentences on what came back and what did not."),
        ], required: ["topic_id", "idea_coverage", "score"])
    )

    /// What the tutor is told once a topic grade has been accepted.
    /// `priorStates` are the review's idea states before this grade: with
    /// them the words know whether the whole topic has now come back, which
    /// is when Go deeper turns to understanding probes and the tutor may say
    /// so. An understanding probe's grade gets its own words
    /// (`MemoryUnderstandingProbe.gradeAcknowledgement`).
    static func topicGradeAcknowledgement(
        grade: MemoryContourGrade,
        topic: MemoryReviewTopic?,
        isOpening: Bool,
        priorStates: [String: MemoryReviewIdeaState] = [:]
    ) -> String {
        let nextTopic = "the next topic's \(MemoryReviewSourceTurn.tagName) line comes first, on its own line, before its opening question."
        if let kind = MemoryUnderstandingProbe.Kind(operation: grade.operation) {
            return MemoryUnderstandingProbe.gradeAcknowledgement(kind: kind, grade: grade) + " On Next, " + nextTopic
        }
        let produced = grade.coverage.filter { $0.status == .produced }.count
        let verdictNote = grade.verdict == .ambiguous
            ? " The question was judged ambiguous, so this grade moves no schedule; say what you meant to ask, briefly."
            : ""
        let open = grade.coverage.contains { $0.status != .produced }
        let next = isOpening
            ? "Reply in at most three sentences: what came back, and that something did not, without naming or paraphrasing any idea graded missing."
            : "Reply to the probe in at most three sentences. If the probed idea is missing again, re-teach it briefly from its source, naming where it came from."
        var after = priorStates
        MemoryReviewIdeaState.fold(grade.coverage, operation: grade.operation, into: &after)
        let topicRecalled = topic.map { MemoryUnderstandingProbe.isRecalled(ideaIDs: $0.ideaIDs, states: after) } ?? false
        let nothingOpen: String
        if open {
            nothingOpen = ""
        } else if topicRecalled {
            nothingOpen = "Nothing in this answer is left missing or partial, and the whole topic has come back; say so in a clause, "
                + "and that Go deeper now goes past recall, in a few words and without pressing it. "
        } else {
            nothingOpen = "Nothing in this answer is left missing or partial; say so in a clause. "
        }
        return "Recorded: \(produced) of \(grade.coverage.count) ideas produced, score \(String(format: "%.2f", grade.score)).\(verdictNote) "
            + next + " "
            + nothingOpen
            + "Then stop: ask no new question and do not move on. The learner chooses Go deeper or Next topic; "
            + "on Next, " + nextTopic
    }

    /// What the tutor is asked when a review planned by topic opens.
    static let topicOpeningRequest = "Start today's memory review. Say in one short sentence which topics today covers, then write the first topic's turn line and ask its opening question."

    /// The opening request for the review a briefing describes.
    static func openingRequest(forBriefing briefing: String?) -> String {
        topics(inBriefing: briefing).isEmpty ? openingRequest : topicOpeningRequest
    }

    /// What the learner's "I don't remember" is sent as: an honest miss that
    /// costs no typing, graded like any answer.
    static let dontRememberMessage = "I don't remember."

    static let setReviewDepthTool = TutorToolDefinition(
        name: "set_review_depth",
        description: "Set how much of a memory review one source (source_id) or a kind of source (source_type such as podcast) gets when the learner says nothing: quick is the contour only, standard adds a probe or two, deep works the full plan. Call it when the learner asks for it — \"keep podcasts quick\", \"go deep on this one\" — and confirm in half a sentence. Depth never skips a contour.",
        parameters: .object([
            "depth": .string("quick, standard, or deep.", allowed: MemoryReviewDepth.allCases.map(\.rawValue)),
            "source_id": .string("One review source to set. Omit when setting a kind of source."),
            "source_type": .string("A kind of source to set the default for, as the briefing names it: article, paper, podcast, book, course, meeting, video."),
        ], required: ["depth"])
    )

    /// What the tutor is told once a grade has been accepted. Identical on
    /// every client, because it is half of what shapes the next reply.
    static func gradeAcknowledgement(grade: MemoryContourGrade, depth: MemoryReviewDepth) -> String {
        let produced = grade.coverage.filter { $0.status == .produced }.count
        let verdictNote = grade.verdict == .ambiguous
            ? " The question was judged ambiguous, so this grade moves no schedule; say what you meant to ask, briefly."
            : ""
        return "Recorded: \(produced) of \(grade.coverage.count) ideas produced, score \(String(format: "%.2f", grade.score)).\(verdictNote) "
            + "Now reply to the learner: in a sentence or two say what came back and that something did not, without naming or paraphrasing any missing idea. "
            + "Then follow this source's depth — \(depth.tutorInstruction). The learner can override with Next or Go deeper. "
            + "Do not turn to another source until they say Next: when this source's depth is spent, end your reply by asking whether to move on or stay, and wait. "
            + "When they do move on, the next source's \(MemoryReviewSourceTurn.tagName) line comes first, on its own line, before that source's question."
    }

    /// What the tutor is asked when the day's review opens: the one user turn
    /// behind the opening message, on every client.
    static let openingRequest = "Start today's memory review. Say in one or two sentences what today covers and why, then ask the first source's contour: what it was about, in my own words, in a sentence or three."

    /// The learner's steer, as the message the tutor hears. The chips and the
    /// spoken words both arrive as this.
    static func steerMessage(_ steer: MemoryReviewSteer) -> String {
        switch steer {
        case .next: return "Next."
        case .deeper: return "Go deeper."
        }
    }
}

/// The line the tutor writes when the review turns to a source.
///
/// The review's transitions are real state — this source is done, that one is
/// starting — but they used to live only in the tutor's prose, which changed
/// subject mid-paragraph while the source strip ticked a checkmark far above.
/// So the tutor marks each turn with one tag line, `<flm_source_turn id="…"/>`,
/// immediately before the source's first question. The Mac splits the reply
/// around it into a heading row the learner sees in the transcript, keeps the
/// raw text in the exchange so reopening the chat rebuilds the heading, and
/// highlights the current chip in the strip. A client that renders no heading
/// strips the line with `stripped(_:)`; nothing else about the review changes.
///
/// Text handling, not a tool call: a tool round trip would have split the
/// reply into two persisted rounds and lost the verdict that precedes the
/// turn on resume, and a text tag costs the model nothing extra to emit.
enum MemoryReviewSourceTurn: Equatable, Sendable {

    static let tagName = "flm_source_turn"

    /// What the tutor is told, in the conduct instructions.
    static let instruction = """
    Whenever you turn to a source — the first one of the day included, and every return to an earlier one — \
    write this line by itself, immediately before that source's first question: <\(tagName) id="SOURCE_ID"/> \
    with that source's id exactly as the briefing gives it. ForeverLM renders the line as a heading that names \
    the source, so the learner sees the review move from one source to the next. Never describe the line, never \
    write the id anywhere else, and never write the line for a question that stays on the current source.
    """

    /// What the tutor is told in a review planned by topic. The line keeps
    /// its tag and carries the topic's id, so the heading, the card and the
    /// transcript follow a topic the way they followed a source.
    static let topicInstruction = """
    Whenever you turn to a topic — the first one of the day included, and every return to an earlier one — \
    write this line by itself, immediately before that topic's first question: <\(tagName) id="TOPIC_ID"/> \
    with the topic's id exactly as the briefing gives it (topic-1, topic-2, …). ForeverLM renders the line as \
    the card's heading. Never describe the line, never write the id anywhere else, and never write the line \
    for a question that stays on the current topic.
    """

    /// The exact line for a source, for clients that compose it themselves.
    static func line(sourceID: String) -> String {
        "<\(tagName) id=\"\(sourceID)\"/>"
    }

    /// One piece of a tutor reply, in order: prose, or a turn to a source.
    enum Part: Equatable, Sendable {
        case text(String)
        case turn(sourceID: String)
    }

    /// The reply split around its turn lines. Prose parts are trimmed and never
    /// empty; a tag with no id is dropped as debris; a reply with no tag is one
    /// text part (or none, when it is blank).
    static func split(_ text: String) -> [Part] {
        var parts: [Part] = []
        var pending = ""
        var rest = Substring(text)
        let opener = "<\(tagName)"
        let closer = "</\(tagName)>"

        func flushText() {
            let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(.text(trimmed)) }
            pending = ""
        }

        // A closing tag (`</flm_source_turn>`) is looked for on its own: the
        // opener's prefix does not match it, and a model that closes the tag
        // must not leave the closer behind as prose.
        func nextTag() -> Range<Substring.Index>? {
            let candidates = [rest.range(of: opener), rest.range(of: closer)].compactMap { $0 }
            return candidates.min(by: { $0.lowerBound < $1.lowerBound })
        }

        while let open = nextTag() {
            pending += rest[..<open.lowerBound]
            let tagStart = open.lowerBound
            guard let close = rest[tagStart...].firstIndex(of: ">") else {
                // An unterminated tag at the very end: streaming debris, not prose.
                rest = ""
                break
            }
            let tag = rest[tagStart...close]
            rest = rest[rest.index(after: close)...]
            if tag.hasPrefix(closer) { continue }
            if let id = attributeValue(named: "id", in: tag) {
                flushText()
                parts.append(.turn(sourceID: id))
            }
        }
        pending += rest
        flushText()
        return parts
    }

    /// The reply with every turn line removed, for a client that shows no heading.
    static func stripped(_ text: String) -> String {
        guard text.contains("<\(tagName)") else { return text }
        let joined = split(text).compactMap { part -> String? in
            if case .text(let prose) = part { return prose }
            return nil
        }.joined(separator: "\n\n")
        return joined
    }

    /// Every turn in the reply, in order.
    static func sourceIDs(in text: String) -> [String] {
        split(text).compactMap { part in
            if case .turn(let sourceID) = part { return sourceID }
            return nil
        }
    }

    /// Streaming text cut before a tag that has not finished arriving, so the
    /// learner never watches `<flm_source_tu` type itself out.
    static func strippingTrailingPartialTag(_ text: String) -> String {
        let opener = "<\(tagName)"
        guard let lastOpen = text.lastIndex(of: "<") else { return text }
        let suffix = text[lastOpen...]
        if suffix.count < opener.count {
            return opener.hasPrefix(suffix) ? String(text[..<lastOpen]) : text
        }
        guard suffix.hasPrefix(opener), !suffix.contains(">") else { return text }
        return String(text[..<lastOpen])
    }

    private static func attributeValue(named name: String, in tag: Substring) -> String? {
        guard let attribute = tag.range(of: "\(name)=") else { return nil }
        var index = attribute.upperBound
        guard index < tag.endIndex else { return nil }
        let quote = tag[index]
        let value: Substring
        if quote == "\"" || quote == "'" {
            index = tag.index(after: index)
            guard let end = tag[index...].firstIndex(of: quote) else { return nil }
            value = tag[index..<end]
        } else {
            let end = tag[index...].firstIndex(where: { $0 == " " || $0 == "/" || $0 == ">" }) ?? tag.endIndex
            value = tag[index..<end]
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Assembling the day's cohort from candidates, minus the one step that needs
/// a vector index (bridges), which the Mac adds on top.
enum MemoryReviewPlanning {

    /// Spine and spacing from a selection, with the reasons the planner and the
    /// tutor read. Roles are decided here and nowhere else.
    static func sources(from selection: CohortSelection, now: Date) -> (sources: [CohortSource], claimed: Set<String>) {
        var sources: [CohortSource] = []
        var claimed = Set<String>()
        for candidate in selection.spine {
            claimed.insert(candidate.sourceID)
            sources.append(cohortSource(candidate, role: .spine, now: now))
        }
        for candidate in selection.spacing where !claimed.contains(candidate.sourceID) {
            claimed.insert(candidate.sourceID)
            sources.append(cohortSource(candidate, role: .spacing, now: now))
        }
        return (sources, claimed)
    }

    /// Today's review with nothing due: the least recently touched sources,
    /// marked so the tutor says nothing was due before offering them. Empty
    /// when the library has nothing consumed at all.
    static func backlogCohort(candidates: [CohortCandidate], unfinished: [String], now: Date) -> LearningCohort {
        let sources = CohortSelector.backlog(candidates: candidates, now: now).map { candidate in
            CohortSource(
                sourceID: candidate.sourceID,
                title: candidate.title,
                sourceType: candidate.sourceType,
                role: .spacing,
                consumedAt: candidate.consumedAt,
                lastDiscussedAt: candidate.lastDiscussedAt,
                reviewCount: candidate.reviewCount,
                confidence: candidate.confidence,
                bridgeTo: nil,
                reason: CohortSelector.backlogReason(candidate: candidate, now: now),
                engagement: candidate.engagement
            )
        }
        return LearningCohort(
            assembledAt: now,
            windowDays: CohortSelector.windowDays,
            sources: sources,
            unfinished: unfinished,
            droppedSpine: 0,
            droppedSpacing: 0,
            isBacklogOnly: true
        )
    }

    private static func cohortSource(_ candidate: CohortCandidate, role: CohortRole, now: Date) -> CohortSource {
        CohortSource(
            sourceID: candidate.sourceID,
            title: candidate.title,
            sourceType: candidate.sourceType,
            role: role,
            consumedAt: candidate.consumedAt,
            lastDiscussedAt: candidate.lastDiscussedAt,
            reviewCount: candidate.reviewCount,
            confidence: candidate.confidence,
            bridgeTo: nil,
            reason: CohortSelector.reason(for: role, candidate: candidate, now: now),
            engagement: candidate.engagement
        )
    }

    enum DecodingFailure: Error, Equatable, Sendable {
        case invalidResponse
    }

    /// Models wrap JSON in prose or fences often enough that locating the object
    /// is worth doing, but a malformed body is an error rather than something to
    /// patch up — a half-understood plan is not better than none.
    static func decodeJSON<T: Decodable>(_ response: String) throws -> T {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end else {
            throw DecodingFailure.invalidResponse
        }
        let json = String(response[start...end])
        guard let data = json.data(using: .utf8) else { throw DecodingFailure.invalidResponse }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DecodingFailure.invalidResponse
        }
    }
}

/// Where a memory review's cards begin, for every client that deals the
/// review as a deck (docs/memory-design.md "Cards"). The chat is untouched;
/// this only says which of its turns share a card.
///
/// A card is one exchange as the learner lives it: the answer they gave, then
/// what the tutor made of it and the question it asks next. The first card is
/// the tutor's opening. A turn that is neither — a side question, a tool row,
/// a blank line — stays on the card it came in on, so a detour never deals a
/// card; and two answers with no reply between them share one.
enum MemoryReviewCardDealing {

    enum Turn: Equatable, Sendable {
        /// The tutor said something; `turnsTo` is the last source its reply
        /// turns to with a `<flm_source_turn>` line, if any.
        case reply(turnsTo: String?)
        /// A turn line drawn as its own row (a heading), naming where the
        /// review moves to: a source, or a topic.
        case turn(to: String)
        /// The learner answered, steered, or asked in the main line.
        case answer
        /// Anything else, which never starts a card.
        case other
    }

    struct Card: Equatable, Sendable {
        /// Where the card's turns sit in the conversation.
        let range: Range<Int>
        /// The source the tutor is on by the end of the card: the last turn
        /// line at or before it. Nil before the first.
        let sourceID: String?
    }

    static func cards(_ turns: [Turn]) -> [Card] {
        guard !turns.isEmpty else { return [] }
        var starts = [0]
        var sourceAtEnd: [String?] = []
        var hasReply = false
        var source: String?
        for (index, turn) in turns.enumerated() {
            switch turn {
            case .answer:
                guard index > 0, hasReply else { continue }
                sourceAtEnd.append(source)
                starts.append(index)
                hasReply = false
            case .reply(let turnsTo):
                hasReply = true
                if let turnsTo { source = turnsTo }
            case .turn(let to):
                source = to
            case .other:
                continue
            }
        }
        sourceAtEnd.append(source)
        return starts.indices.map { position in
            let end = position + 1 < starts.count ? starts[position + 1] : turns.count
            return Card(range: starts[position]..<end, sourceID: sourceAtEnd[position])
        }
    }

    /// A review planned by topic, dealt one card per topic: a card begins
    /// where the tutor turns to a new topic, so the opening answer, the reply,
    /// every probe and its answer, and the steer that ends it share one card.
    /// Prose the tutor writes before the turn line (closing the last topic)
    /// stays on the card it closes. The first card holds everything up to and
    /// including the opening of the first topic.
    static func topicCards(_ turns: [Turn]) -> [Card] {
        guard !turns.isEmpty else { return [] }
        var starts = [0]
        var topics: [String?] = [nil]
        for (index, turn) in turns.enumerated() {
            let target: String?
            switch turn {
            case .turn(let to): target = to
            case .reply(let turnsTo): target = turnsTo
            case .answer, .other: target = nil
            }
            guard let target, target != topics[topics.count - 1] else { continue }
            if topics[topics.count - 1] == nil {
                topics[topics.count - 1] = target
            } else {
                starts.append(index)
                topics.append(target)
            }
        }
        return starts.indices.map { position in
            let end = position + 1 < starts.count ? starts[position + 1] : turns.count
            return Card(range: starts[position]..<end, sourceID: topics[position])
        }
    }

    /// The card a selection lands on: the one chosen, or the newest when none
    /// is (or the chosen one is gone). Nil when there is no card yet.
    static func resolvedIndex(_ selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selected, (0..<count).contains(selected) else { return count - 1 }
        return selected
    }

    /// The selection after moving one card: nil once the move lands on the
    /// newest, which is where a new card also brings the deck.
    static func step(_ selected: Int?, by offset: Int, count: Int) -> Int? {
        guard let current = resolvedIndex(selected, count: count) else { return nil }
        let target = min(max(current + offset, 0), count - 1)
        return target == count - 1 ? nil : target
    }
}
