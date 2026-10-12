#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// Which account-level model selection a task follows. This is part of the
/// portable Settings contract so native and web clients cannot quietly route
/// the same task through different defaults.
public enum AITaskModelDefault: String, Codable, Equatable, Sendable {
    case chat
    case backgroundText
    case backgroundMultimodal
}

/// User-facing Settings metadata for one model-bearing app task.
public struct AITaskSettingsDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let modelDefault: AITaskModelDefault
    public let showInAdvancedSettings: Bool
    public let requiresVision: Bool

    public var usesBackgroundModelDefault: Bool {
        modelDefault != .chat
    }

    public var usesMultimodalBackgroundModelDefault: Bool {
        modelDefault == .backgroundMultimodal
    }
}

/// The single ordered task catalog rendered by macOS, iOS, and Web Studio.
///
/// IDs are durable `AITask` raw values. The array order is presentation order,
/// so clients should filter this list rather than sorting their own copies.
public enum AITaskSettingsCatalog {
    public static let version = 37

    public static let tasks: [AITaskSettingsDescriptor] = [
        task(
            "chat",
            "Review Session",
            "Multi-turn explain-it-back review tutoring",
            modelDefault: .chat,
            advanced: false
        ),
        task(
            "review_grading",
            "Review Grading",
            "Assess a completed review from the learner's answers"
        ),
        // Written ahead of time for the sources a review is likely to be
        // about, with nobody waiting on it, so it is background work with a
        // model of its own (product owner, 2026-10-11: "each background task
        // should have a model set for it").
        task(
            "realtime_review_preparation",
            "Review Questions",
            "Write a source's review questions and answer guide ahead of a review"
        ),
        task(
            "mobile_review",
            "Hands-Free Review Grading",
            "Grade hands-free review answers on iPhone and CarPlay"
        ),
        task(
            "mobile_voice_agent",
            "Hands-Free Command Routing",
            "Route hands-free playback and study commands on iPhone"
        ),
        // A chat mode the learner starts and watches, not background work
        // (product owner, 2026-09-27): it runs on the chat's model and is not one of
        // Background's specific tasks.
        task(
            "deep_research",
            "Deep Research",
            "Run provider-agent or multi-pass web research and collect sources for review",
            modelDefault: .chat,
            advanced: false
        ),
        // Discover in a notebook's Add sources: the learner starts it and
        // waits on the list, so it runs on the chat's model, the one with the
        // provider's own web search, rather than on Background's.
        task(
            "source_discovery",
            "Source Discovery",
            "Search the web for sources a notebook is missing, with one line on why each fits",
            modelDefault: .chat,
            advanced: false
        ),
        // A chat's own purposes that nobody waits on run on Background's
        // model, each with a model of its own, not on the chat's.
        task(
            "chat_title",
            "Chat Title",
            "Name a chat from its first exchange"
        ),
        task(
            "chat_history_compaction",
            "Chat History Compaction",
            "Summarize a long chat's earlier turns so it stays within the chat model's window"
        ),
        task(
            "transcript_formatting",
            "Transcript Formatting",
            "Format raw YouTube transcripts into readable sections"
        ),
        task(
            "podcast_speaker_identification",
            "Podcast Speaker Identification",
            "Research podcast hosts and guests, then match them to transcript speakers"
        ),
        task(
            "podcast_youtube_matching",
            "Podcast YouTube Matching",
            "Find and rank YouTube uploads that represent the same podcast episode"
        ),
        task(
            "slide_frame_classification",
            "Slide Deduplication",
            "Tell a real slide from a camera shot of the room, so duplicate frames get hidden — needs a vision model",
            modelDefault: .backgroundMultimodal,
            requiresVision: true
        ),
        task(
            "slide_citation_extraction",
            "Slide Citation Extraction",
            "Read papers cited on a talk's slides — needs a vision model",
            modelDefault: .backgroundMultimodal,
            requiresVision: true
        ),
        task(
            "paper_figure_understanding",
            "Paper Figure Understanding",
            "Explain paper figures and subfigures from the original PDF — needs a vision model",
            modelDefault: .backgroundMultimodal,
            requiresVision: true
        ),
        task(
            "lecture_paper_discovery",
            "Lecture Paper Discovery",
            "Read explicit paper citations from lecture notes, syllabi, slides, and other course materials"
        ),
        task(
            "meeting_paper_discovery",
            "Meeting Paper Discovery",
            "Find academic papers explicitly mentioned in meeting transcripts and notes"
        ),
        task(
            "paper_reference_extraction",
            "Paper Reference Extraction",
            "Read a paper's reference list for the papers it cites"
        ),
        task(
            "article_link_discovery",
            "Article Link Discovery",
            "Read an article's links for the sources it points at — other articles, papers, videos, podcasts"
        ),
        task(
            "journal_article_matching",
            "Feed Article Matching",
            "Judge which new articles and posts from followed feeds — journals, blogs, newsletters — belong in your notebooks"
        ),
        task(
            "citation_resolution",
            "Citation Web Lookup",
            "Find a cited paper's DOI by web search when a catalog lookup can't identify it"
        ),
        task(
            "embedding",
            "Text Embedding",
            "Semantic search embeddings",
            advanced: false
        ),
        task(
            "source_classification",
            "Source Classification",
            "Classify sources as article, paper, or book"
        ),
        task(
            "paper_metadata",
            "Paper Metadata",
            "Extract title, author, journal, year, and DOI from papers"
        ),
        task(
            "paper_narration_preparation",
            "Source Content Cleanup",
            "Remove paper or article noise and repair boxed-sidebar order without rewriting source prose"
        ),
        task(
            "paper_read_aloud_preparation",
            "Text-to-Speech Preparation",
            "Adapt figures, captions, tables, equations, and other visual source content for listening"
        ),
        task(
            "automatic_audio_filtering",
            "Automatic Audio Filtering",
            "Match source metadata against your natural-language automatic-audio rules"
        ),
        task(
            "paper_attachment_check",
            "Paper Attachment Check",
            "Decide whether an attached PDF is clearly the wrong paper"
        ),
        task(
            "paper_browser_agent",
            "Paper Browser Agent",
            "Navigate paper websites to find open-access PDFs"
        ),
        task(
            "article_metadata",
            "Article Metadata",
            "Extract title, author, year from articles"
        ),
        task(
            "article_chrome_filtering",
            "Article Chrome Filtering",
            "Tell a web page's article from the site around it so navigation, share bars, comment forms, and newsletter appeals never reach the reader"
        ),
        task(
            "book_author",
            "Book Metadata",
            "Extract title, subtitle, author, and edition from books"
        ),
        task(
            "duplicate_detection",
            "Duplicate Detection",
            "Detect duplicate papers via title similarity"
        ),
        task(
            "topic_summarization",
            "Notebook Notes Merge",
            "Merge a new chat insight into existing notebook notes"
        ),
        task(
            "book_chapter_splitting",
            "Book Chapter Splitting",
            "Choose real book chapter boundaries"
        ),
        task(
            "meeting_session_details",
            "Meeting Session Details",
            "Extract meeting topic and presenter from session files"
        ),
        task(
            "meeting_action_items",
            "Meeting Action Items",
            "Extract action items from a meeting transcript"
        ),
        task(
            "lecture_note_matching",
            "Lecture-Note Matching",
            "Match lecture videos to PDF notes"
        ),
        task(
            "course_ordering",
            "Course Ordering",
            "Suggest optimal course learning order"
        ),
        task(
            "course_metadata",
            "Course Metadata",
            "Fill course title, code, institution, and instructors from an imported playlist"
        ),
        task(
            "course_lecture_naming",
            "Lecture Titles",
            "Name each lecture of a course for what it teaches, from its transcript, keeping a video's title when it already says so"
        ),
        task(
            "cohort_session_plan",
            "Review Session Plan",
            "Choose what today's review should cover across this week's sources and older material due again"
        ),
        task(
            "cohort_session_close",
            "Review Session Close",
            "Rewrite what you understand about each source discussed, and summarize the session"
        ),
        task(
            "source_idea_extraction",
            "Idea Extraction",
            "Extract the handful of ideas a source asks to be remembered, once, when you have taken it in"
        ),
        task(
            "card_drafting",
            "Card Drafting",
            "Draft Memory cards from a source's text and the questions, highlights and ideas made of it, for you to keep, edit or skip"
        ),
        task(
            "card_variation",
            "Card Variation",
            "Reword a card you have remembered twice so it asks for the same answer from another angle, and check each rewording"
        ),
        // Asked by the learner's Go Deeper on a card, and waited for: the
        // chat's model, not background work.
        task(
            "card_go_deeper",
            "Go Deeper",
            "Ask a question that goes past a card you remembered (the principle behind it, where else it applies, what would prove it wrong, or what it is like) and reply to your answer",
            modelDefault: .chat
        ),
        // Asked by the learner's Check on a card, and waited for, as Go
        // Deeper is: the chat's model, not background work.
        task(
            "card_answer_check",
            "Card Answer Check",
            "Check the answer you typed or said to a card against its back, say what was missing, and suggest Remembered or Forgot",
            modelDefault: .chat
        ),
        task(
            "card_wording_check",
            "Card Wording Check",
            "Check that every card's question and answer stand on their own, naming what they are about rather than \u{201C}this lecture\u{201D} or \u{201C}the paper\u{201D}, and reword one that does not before it is saved"
        ),
        task(
            "mnemonic_reading_writing",
            "Mnemonic Reading Writing",
            "Write the recall questions a book or source is read with, each after the passage it tests"
        ),
        task(
            "notebook_naming",
            "Notebook Naming",
            "Name a notebook made without a name, and write its card description, from its sources and chats"
        ),
        task(
            "map_summaries",
            "Canvas Summaries",
            "Write the summary of each region on the Canvas at two levels of abstraction, and a sentence about what is in view"
        ),
        // Asked by the learner on a selection they made, and watched: the
        // chat's model, not background work (docs/sensemaking-design.md).
        task(
            "canvas_ask",
            "Ask the Canvas",
            "Answer a question asked of cards on the Canvas (what connects them, how they relate, what they leave open) as proposals you keep or dismiss",
            modelDefault: .chat
        ),
        task(
            "atlas_writing",
            "Atlas Writing",
            "Lay a topic out as concepts at several levels of abstraction, each grounded in passages from your library",
            modelDefault: .chat
        ),
        task(
            "source_levels",
            "Reading Levels",
            "Write a source's reading levels for the Reader: its gist, a sentence per section and per paragraph, and its key terms"
        ),
        task(
            "course_curriculum_plan",
            "Course Planning",
            "Plan a generated course: choose its modules and which library sources each one reads"
        ),
        task(
            "course_lesson_writing",
            "Course Lesson Writing",
            "Write each module's lesson and exercise sheet from the sources it reads"
        ),
        task(
            "explainer_writing",
            "Explainer Writing",
            "Write a spoken explainer of a paper, article, episode, video or meeting from its full text, for the text-to-speech voice"
        ),
        task(
            "audio_overview_writing",
            "Audio Overview Writing",
            "Write a notebook's audio overview: one spoken script over its sources, for the text-to-speech voice"
        ),
        task(
            "report_writing",
            "Report Writing",
            "Write a notebook's report from its sources, with citations: a briefing, a study guide, questions for a meeting, feedback on a document, or a format you describe"
        ),
        task(
            "walkthrough_writing",
            "Walkthrough Writing",
            "Write a paper's walkthrough as a deck of cards: its argument in chapters, one point a card, its figures, and questions along the way"
        ),
        task(
            "walkthrough_animation",
            "Walkthrough Animation",
            "Draw the small HTML animation a walkthrough step plays in the chat beside a figure"
        ),
        task(
            "lecture_quiz_writing",
            "Lecture Quiz Writing",
            "Write the quiz that follows each lecture of a course, from the lecture's transcript"
        ),
        task(
            "course_quiz_writing",
            "Course Quiz Writing",
            "Write a course's checkpoint quizzes and its course test, across the lectures each one covers"
        ),
        task(
            "course_textbook_readings",
            "Textbook Readings",
            "Choose the parts of a textbook to read with each lecture of a course, for where you're coming from and what you need"
        ),
    ]

    public static var advancedTasks: [AITaskSettingsDescriptor] {
        tasks.filter(\.showInAdvancedSettings)
    }

    public static func descriptor(forRawID rawID: String) -> AITaskSettingsDescriptor? {
        tasks.first { $0.id == rawID }
    }

    public static func encodedTasks() -> String? {
        guard let data = try? JSONEncoder().encode(tasks) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func task(
        _ id: String,
        _ displayName: String,
        _ description: String,
        modelDefault: AITaskModelDefault = .backgroundText,
        advanced: Bool = true,
        requiresVision: Bool = false
    ) -> AITaskSettingsDescriptor {
        AITaskSettingsDescriptor(
            id: id,
            displayName: displayName,
            description: description,
            modelDefault: modelDefault,
            showInAdvancedSettings: advanced,
            requiresVision: requiresVision
        )
    }
}
