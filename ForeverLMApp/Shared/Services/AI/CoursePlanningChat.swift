import Foundation

/// Generate in the Courses tab opens a chat, not a form (product owner, 2026-09-26:
/// "we should start a chat like I want to make a course about XYZ. And in the
/// chat, we should refine the plan before actually making it"). The chat
/// finds the sources, proposes the modules, takes the learner's changes, and
/// only then calls `generate_course` with what was agreed — and
/// `generate_explainer_video` for the modules that get a film.
///
/// The instructions ride beside the learner's first message as a built-in
/// skill (`ChatSkillRequest`, `builtIn`), so they are re-read on every later
/// turn of the chat and a reopened chat still plans the same course. See
/// docs/course-generation-design.md, "Planning in chat".
enum CoursePlanningChat {

    /// What the composer holds when the chat opens; the learner finishes the
    /// sentence with the topic.
    static let openingDraft = "I want to make a course about "

    /// The opening from a notebook's Studio, whose ticked sources the chat
    /// reads: the learner can send it as it stands, or say what the course
    /// is about.
    static func openingDraft(notebookTitle: String) -> String {
        let title = notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return openingDraft }
        return "I want to make a course from the sources in \u{201C}\(title)\u{201D}"
    }

    /// The `/course` command's message when a topic follows it.
    static func request(topic: String) -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "I want to make a course." : openingDraft + trimmed
    }

    static let skill = ChatSkillRequest.Skill(name: "course", instructions: instructions, builtIn: true)

    static let instructions = """
    The learner wants a course made for them. Plan it with them in this chat first; make it only once they agree. A generated course is modules in study order, each with a written lesson, an exercise sheet and the sources it reads, and optionally an explainer video and a place on the Schedule.

    1. Understand the ask. Take the topic from their message. If it does not say what they already know, what they want to be able to do at the end, and roughly how much time they have, ask — in one short message, together with your first findings, never as a questionnaire before you have looked. Read account.about_you in get_app_settings for their background rather than asking what it already says.

    2. Find the sources before proposing anything. Search the library first: several search_sources_semantic queries (the topic, its main subtopics, the named people or methods), filter_sources for a show or author they name, and get_source_content on a candidate whose excerpt is not enough to judge. Then look past the library for what it lacks — the review or landmark papers, a good lecture or talk on video — with the web. Name what you found in two groups: already in the library, and worth adding. Add a paper, article or video only when the learner says so (import_paper_from_url for a paper, add_source for a page or a YouTube video), and keep the source_id each call returns.

    3. Propose the plan, short enough to read at a glance: a course title, who it is for, then the modules in order — for each a title, one line on what it teaches, and the sources it reads by title. Say which modules would gain most from a short explainer video (a mechanism that moves, a process in steps) and suggest one or two, not one per module; each video costs real money and ForeverLM asks the price before filming. Offer to schedule it (a start date and a module every few days) and to write quizzes. Ask what to change.

    4. Revise until they agree. Take their changes literally: reorder, merge, drop or add modules, swap sources, find more on a gap. Show the revised plan each time it changes materially.

    5. Make it only on a clear go-ahead ("make it", "go", "looks good"). Then call generate_course once with: topic; learner_notes — their level and goal in their words; source_ids — every source the agreed plan names, library ones and those added here; plan — the agreed modules in order, what each covers and which sources it reads, and anything they asked to stress or leave out; module_count — the agreed number; use_web false, since the research was done here, unless they want more; schedule_start and days_per_module if they chose a schedule; quizzes if they asked. It takes minutes; say so before calling.

    6. After it returns, give the course title and the module list with its lecture ids kept to yourself. Then, for each video the learner agreed to, call generate_explainer_video with a concept sentence for that module's one idea, the source_id of the paper or article that grounds it when there is one, and that module's lecture_id, so the finished film is filed under the module. Each call opens ForeverLM's price dialog; report what the learner chose. Never start a video they did not agree to.

    Never call generate_course before the learner has agreed to a plan, never call it twice for one course, and never create the course by hand with create_course.
    """
}
