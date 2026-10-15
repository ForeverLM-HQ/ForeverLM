import Foundation

/// Every model-bearing text step in ForeverLM, shared by every app target.
///
/// Keeping the identity in a lightweight file is deliberate: iPhone and CarPlay
/// must resolve the same account-level route as macOS instead of maintaining a
/// second set of model literals. Platform-specific presentation and prompts live
/// in extensions compiled by the corresponding target.
enum AITask: String, CaseIterable, Codable, Identifiable, Sendable {
    case chat = "chat"
    case reviewGrading = "review_grading"
    case realtimeReviewPreparation = "realtime_review_preparation"
    case mobileReview = "mobile_review"
    case mobileVoiceAgent = "mobile_voice_agent"
    case deepResearch = "deep_research"
    /// Discover, in a notebook's Add sources: one web search for the sources
    /// the notebook is missing, each with one line on why it fits. The model
    /// judges fit; ForeverLM decides what each address is.
    case sourceDiscovery = "source_discovery"
    /// Names a chat from its first exchange, in place of the opening message
    /// it was titled with. The raw value is the ledger label it always had.
    case chatTitle = "chat_title"
    /// Folds a long chat's older turns into the summary its next turns carry,
    /// so the chat stays inside its model's window. The raw value is the
    /// ledger label it always had.
    case chatHistoryCompaction = "chat_history_compaction"
    case transcriptFormatting = "transcript_formatting"
    case podcastSpeakerIdentification = "podcast_speaker_identification"
    case podcastYouTubeMatching = "podcast_youtube_matching"
    case slideFrameClassification = "slide_frame_classification"
    case slideCitationExtraction = "slide_citation_extraction"
    case paperFigureUnderstanding = "paper_figure_understanding"
    case lecturePaperDiscovery = "lecture_paper_discovery"
    case meetingPaperDiscovery = "meeting_paper_discovery"
    /// Reads a paper's reference list for the papers it cites.
    case paperReferenceExtraction = "paper_reference_extraction"
    /// Reads an article's links for the sources it points at.
    case articleLinkDiscovery = "article_link_discovery"
    /// Judges which newly published journal articles belong in which Notebooks.
    case journalArticleMatching = "journal_article_matching"
    case citationResolution = "citation_resolution"
    case embedding = "embedding"
    case sourceClassification = "source_classification"
    case paperMetadata = "paper_metadata"
    case paperNarrationPreparation = "paper_narration_preparation"
    case paperTextToSpeechPreparation = "paper_read_aloud_preparation"
    case automaticAudioFiltering = "automatic_audio_filtering"
    case paperAttachmentCheck = "paper_attachment_check"
    case paperBrowserAgent = "paper_browser_agent"
    case articleMetadata = "article_metadata"
    case articleChromeFiltering = "article_chrome_filtering"
    case bookAuthor = "book_author"
    case duplicateDetection = "duplicate_detection"
    // The raw ID is durable and already synced to existing installs. The task
    // was historically mislabeled as topic summarization, but its only product
    // behavior is merging new chat insights into Notebook notes.
    case notebookNotesMerge = "topic_summarization"
    case bookChapterSplitting = "book_chapter_splitting"
    /// Reads the lines OCR took off a scanned book's pages against each
    /// page's picture and corrects them to what the page prints, before the
    /// book is split into chapters (`ScannedPageProofreading`).
    case scannedPageProofreading = "scanned_page_proofreading"
    case meetingSessionDetails = "meeting_session_details"
    case meetingActionItems = "meeting_action_items"
    case lectureNoteMatching = "lecture_note_matching"
    case courseOrdering = "course_ordering"
    case courseMetadata = "course_metadata"
    /// Names each lecture of a course for what it teaches, from its
    /// transcript, notes and slides, keeping a video's title that already
    /// says so.
    case courseLectureNaming = "course_lecture_naming"
    case cohortSessionPlan = "cohort_session_plan"
    case sourceIdeaExtraction = "source_idea_extraction"
    /// Drafts Memory cards from a source — its whole text, and the questions,
    /// highlights and ideas already made of it — for the learner to keep,
    /// edit or skip in Memory's To Check (docs/memory-design.md, "Drafting").
    case cardDrafting = "card_drafting"
    /// Go Deeper in the card review: a question that goes past a card the
    /// learner just remembered — the principle behind it, where else it
    /// applies, what would prove it wrong, or what it is like — and a short
    /// reply to their answer (docs/memory-design.md, "Go Deeper on a card").
    case cardGoDeeper = "card_go_deeper"
    /// Check in the card review: the learner's typed or said answer judged
    /// against the card's back — right, partly or wrong, with one line on what
    /// was missing — which decides the grade the learner confirms or
    /// overrides (docs/memory-design.md, "The answer is checked").
    case cardAnswerCheck = "card_answer_check"
    /// The gate every card face passes before it is saved: one call checks a
    /// batch of cards for a question or answer that points at "this
    /// lecture" or "the paper" without naming it, and rewords the ones that
    /// do (docs/memory-design.md, "A card stands on its own").
    case cardWordingCheck = "card_wording_check"
    /// Writes a mnemonic reading's recall questions, a source at a time: a
    /// book's chapters, or any chapter, paper or article, read as its own
    /// text with a question after the passage it tests
    /// (docs/memory-design.md, "Mnemonic reading").
    case mnemonicReadingWriting = "mnemonic_reading_writing"
    /// Names a notebook made without a name, title and card description,
    /// from its sources and the first exchange of its chats
    /// (docs/notebooks-design.md, "A notebook names itself").
    case notebookNaming = "notebook_naming"
    /// Says which line breaks of a paste into a Page end a paragraph, so
    /// text copied from a PDF, which arrives one printed line at a time, is
    /// joined back into its paragraphs (`PastedLineJoining`).
    case pastedLineJoining = "pasted_line_joining"
    /// Writes the Map's summaries: a notebook cluster's or a region's gist at
    /// two levels of abstraction, and a sentence about what is in view
    /// (docs/knowledge-map-design.md, "Levels of abstraction").
    case mapSummaries = "map_summaries"
    /// Answers a question asked of a selection on the Canvas (what bridges
    /// these cards, how they relate, what they leave open) as proposals the
    /// learner keeps or dismisses (docs/sensemaking-design.md, "Ask the Canvas").
    case canvasAsk = "canvas_ask"
    /// Changes the Canvas as the learner says, from one spoken request: the
    /// cards set down, moved, grouped, joined or taken off and the regions
    /// drawn, as edits the Canvas applies the moment each arrives
    /// (`KnowledgeMapVoice`, `CanvasVoice`).
    case canvasVoice = "canvas_voice"
    /// Writes an Atlas: a topic laid out as concepts at several levels of
    /// abstraction, each grounded in passages from the library, and deepens
    /// one concept when the learner focuses it (docs/sensemaking-design.md,
    /// "Atlas").
    case atlasWriting = "atlas_writing"
    /// Writes a source's reading levels for the Reader: its gist, a sentence
    /// per section and per paragraph, and its key terms
    /// (docs/sensemaking-design.md, "Levels in the Reader").
    case sourceLevels = "source_levels"
    case courseCurriculumPlan = "course_curriculum_plan"
    case courseLessonWriting = "course_lesson_writing"
    case explainerWriting = "explainer_writing"
    /// Writes a notebook's audio overview: one spoken script over the
    /// notebook's sources, and the condensed accounts of any source the
    /// model's window cannot take whole.
    case audioOverviewWriting = "audio_overview_writing"
    /// Writes a notebook's report — a briefing, a study guide, questions for
    /// a meeting, feedback on a document, or the learner's own format — from
    /// its sources, and the condensed accounts of any source the model's
    /// window cannot take whole.
    case reportWriting = "report_writing"
    /// Writes a paper's step-by-step walkthrough for the Reader: its figures,
    /// key passages and questions.
    case walkthroughWriting = "walkthrough_writing"
    /// Draws the small animation a walkthrough step shows beside a figure.
    case walkthroughAnimation = "walkthrough_animation"
    /// Writes the quiz that follows a course lecture, from its transcript:
    /// ahead of time with the rest of the course's quizzes, or when the
    /// learner opens one that was never written.
    case lectureQuizWriting = "lecture_quiz_writing"
    /// Writes a course's checkpoint quizzes and its course test, across the
    /// lectures each covers.
    case courseQuizWriting = "course_quiz_writing"
    /// Chooses the parts of a textbook a learner reads with each lecture of a
    /// course, for where they are coming from and what they need.
    case courseTextbookReadings = "course_textbook_readings"

    var id: String { rawValue }

    /// Whether this task follows the multimodal rather than text-only
    /// Background default. Kept in the lightweight task core so iPhone and
    /// CarPlay resolve the same portable Settings contract as macOS and web.
    var usesMultimodalBackgroundModelDefault: Bool {
        guard let descriptor = AITaskSettingsCatalog.descriptor(forRawID: rawValue) else {
            preconditionFailure("Missing portable AI task Settings descriptor for \(rawValue)")
        }
        return descriptor.usesMultimodalBackgroundModelDefault
    }
}

/// One atomic, versioned account preference for a model route. Provider and
/// model may never be persisted independently: observing half of a route can
/// send a request to a provider/model pair the learner never selected.
struct AIModelRoutePreference: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let provider: String
    let model: String
    let effort: String?
    let speed: String?

    init(
        provider: String,
        model: String,
        effort: String? = nil,
        speed: String? = nil,
        version: Int = currentVersion
    ) {
        self.version = version
        self.provider = provider
        self.model = model
        self.effort = effort
        self.speed = speed
    }

    var isValid: Bool {
        version == Self.currentVersion
            && !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A route that has passed platform preference resolution and is safe to put
/// on the wire. Mobile request builders accept this type instead of a model
/// string, making it impossible for a call site to smuggle in a literal model.
struct ResolvedAITextRoute: Equatable, Sendable {
    let task: AITask
    let provider: String
    let model: String
    let effort: String?
    /// The account's `AIDataPolicy` switch as read when the route was
    /// resolved, so an OpenRouter body built from this route carries the
    /// deny preference without the builder reaching for a preference store.
    let deniesDataCollection: Bool
    /// The endpoints the model may run on when its host choice keeps it in
    /// one region (`OpenRouterHostPreference.region`), read when the route
    /// was resolved; nil for any host.
    let regionEndpointTags: [String]?

    init(
        task: AITask,
        provider: String,
        model: String,
        effort: String? = nil,
        deniesDataCollection: Bool = false,
        regionEndpointTags: [String]? = nil
    ) {
        self.task = task
        self.provider = provider
        self.model = model
        self.effort = effort
        self.deniesDataCollection = deniesDataCollection
        self.regionEndpointTags = regionEndpointTags
    }

    /// This route, kept to the given endpoints.
    func confined(to tags: [String]) -> ResolvedAITextRoute {
        ResolvedAITextRoute(
            task: task,
            provider: provider,
            model: model,
            effort: effort,
            deniesDataCollection: deniesDataCollection,
            regionEndpointTags: tags
        )
    }
}

/// Account-wide transport policy for ordinary managed text inference.
///
/// Model preferences keep the canonical provider/model identity selected in
/// Settings; the mode picks only the transport. OpenRouter is the one text
/// transport. There is no first-party mode — the labs' own APIs carry media,
/// never text — and Ramp Router was removed on 2026-09-23 (the product owner: "you can
/// do only openrouter for now; ramp can be purged"). The enum stays so the
/// server-named policy has a type, and so a second router is one case away.
/// Reverting the `ramp-router` change (tag `ramp-router-last`) brings Ramp back.
enum AITextRoutingMode: String, Codable, CaseIterable, Sendable {
    case openRouter

    /// The transport a device opens with before the server has named one, and
    /// the one a server token this build does not understand resolves to. Never
    /// "no policy": the app has no state where text has no transport.
    static var shippedDefault: AITextRoutingMode { .openRouter }

    /// The router a managed account requires, as the server names it. The wire
    /// token is a transport name rather than this enum's case name so the
    /// server can keep naming routers the way the billing rail does.
    init?(serverToken: String) {
        switch serverToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openrouter": self = .openRouter
        default: return nil
        }
    }
}

enum AIModelPreferenceKey {
    static let defaultChatRoute = "aiRoute.defaultChat"
    /// The effort last picked from a chat's effort control, which a chat with
    /// no effort of its own starts on (`KeychainService.chosenChatEffort`).
    static let defaultChatEffort = "aiRoute.defaultChat.effort"
    /// Background text-only route. The unsuffixed key is retained so existing
    /// selections and older clients continue to agree on the text default.
    static let backgroundRoute = "aiRoute.background"
    static let backgroundMultimodalRoute = "aiRoute.background.multimodal"
    /// The model a Doc's Edit with AI runs on (`KeychainService.docsRoute`).
    /// Absent, Docs follow the Default Model.
    static let docsRoute = "aiRoute.docs"
    static let textRoutingMode = "aiRoute.textRoutingMode"

    static func taskRoute(_ task: AITask) -> String {
        "aiRoute.task.\(task.rawValue)"
    }
}
