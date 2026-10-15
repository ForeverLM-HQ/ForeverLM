import Foundation
import Testing
@testable import ForeverLMCore

@Suite("ForeverLM core")
struct ForeverLMCoreTests {
    @Test("Conversation transcript preserves Markdown and skips empty turns")
    func conversationTranscriptFormatting() {
        let transcript = ConversationTranscriptFormatter.plainText(from: [
            .init(speaker: .user, content: "  How does this work?  "),
            .init(speaker: .assistant, content: "**Carefully.**\n\n```swift\nlet answer = 42\n```"),
            .init(speaker: .assistant, content: "\n  \n"),
        ])

        #expect(transcript == """
        You:
        How does this work?

        ForeverLM:
        **Carefully.**

        ```swift
        let answer = 42
        ```
        """)
    }

    @Test("Article position uses one stable cross-platform encoding")
    func articlePositionEncoding() {
        #expect(ArticleReadingPositionLocator(scrollFraction: -0.5).encoded == #"{"webScrollFraction":0}"#)
        #expect(ArticleReadingPositionLocator(scrollFraction: 0.12341).encoded == #"{"webScrollFraction":0.1234}"#)
        #expect(ArticleReadingPositionLocator(scrollFraction: 0.12344).encoded == #"{"webScrollFraction":0.1234}"#)
        #expect(ArticleReadingPositionLocator(scrollFraction: 0.123456).encoded == #"{"webScrollFraction":0.1235}"#)
        #expect(ArticleReadingPositionLocator(scrollFraction: 1.7).encoded == #"{"webScrollFraction":1}"#)
        #expect(ArticleReadingPositionLocator(scrollFraction: .nan).encoded == nil)
    }

    @Test("Article position rejects other locator formats")
    func articlePositionDecoding() {
        #expect(ArticleReadingPositionLocator(encoded: #"{"webScrollFraction":0.42137}"#)?.webScrollFraction == 0.4214)
        #expect(ArticleReadingPositionLocator(encoded: #"{"relativePath":"ch3.xhtml","scrollFraction":0.42}"#) == nil)
        #expect(ArticleReadingPositionLocator(encoded: #"{"positionSeconds":421,"watchedSeconds":900}"#) == nil)
        #expect(ArticleReadingPositionLocator(encoded: "not json") == nil)
        #expect(ArticleReadingPositionLocator(encoded: nil) == nil)
    }

    @Test("Source metadata is deterministic")
    func sourceMetadata() {
        #expect(ForeverLMCore.canonicalSourceType(" XPost ") == "xpost")
        #expect(ForeverLMCore.canonicalSourceType("manual") == "article")
        #expect(ForeverLMCore.youtubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ?t=5") == "dQw4w9WgXcQ")
        #expect(ForeverLMCore.youtubeVideoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(ForeverLMCore.youtubeThumbnailURL(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "https://img.youtube.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        #expect(ForeverLMCore.youtubeEmbedURL(for: "https://youtu.be/dQw4w9WgXcQ") == "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
        #expect(ForeverLMCore.youtubeVideoID(from: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(ForeverLMCore.youtubeVideoID(from: "https://www.youtube.com/watch?v=abc%3Fautoplay%3D1") == nil)
        #expect(ForeverLMCore.youtubeThumbnailURL(for: "https://www.youtube.com/watch?v=abc%2Fdef") == nil)
        // Every provider shares one Meetings tab; provider is a badge on the
        // row, not the tab a session is allowed to appear in.
        #expect(ForeverLMCore.sourceTabID(sourceType: "meeting", discoveryOrigin: "readAI") == "meetings")
        #expect(ForeverLMCore.sourceTabID(sourceType: "meeting", discoveryOrigin: "localMeetings") == "meetings")
        #expect(ForeverLMCore.sourceTabID(sourceType: "meeting", discoveryOrigin: "googleDriveMeetings") == "meetings")
        #expect(ForeverLMCore.sourceTabID(sourceType: "meeting") == "meetings")
        #expect(ForeverLMCore.sourceTabID(sourceType: "meeting", discoveryOrigin: "zoom") == "meetings")
        // Zoom recordings are stored as meetings from ingest onward. One synced
        // from a build that still typed it a video routes on its URL shape, so
        // it reaches Meetings rather than sitting among YouTube videos.
        #expect(ForeverLMCore.sourceTabID(
            sourceType: "video",
            url: "https://acme.zoom.us/rec/share/recording-id"
        ) == "meetings")
        #expect(ForeverLMCore.sourceTabID(
            sourceType: "video",
            url: "https://youtube.com/watch?v=dQw4w9WgXcQ"
        ) == "video")

        // One Zoom account is one series, and the id is derived rather than
        // generated so two Macs migrating the same library agree on it.
        let series = ForeverLMCore.zoomMeetingSeries(
            forRecordingURL: "https://acme.zoom.us/rec/share/recording-id"
        )
        #expect(series?.id == "zoom:acme.zoom.us")
        #expect(series?.title == "acme.zoom.us")
        #expect(
            ForeverLMCore.zoomMeetingSeries(
                forRecordingURL: "https://acme.zoom.us/rec/play/other-id"
            )?.id == series?.id
        )
        #expect(ForeverLMCore.zoomMeetingSeries(forRecordingURL: "https://acme.zoom.us/j/123") == nil)
        #expect(ForeverLMCore.zoomMeetingSeries(forRecordingURL: "https://youtu.be/dQw4w9WgXcQ") == nil)
    }

    @Test("Read tracking has one native and browser eligibility rule")
    func readTrackingEligibility() {
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "article",
            url: "https://example.com/lesson"
        ))
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "manual",
            url: "http://example.com/note"
        ))
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "unclassified",
            isWebArticle: true
        ))
        // A paper owns read state wherever its text lives: a direct PDF URL, a
        // downloaded PDF, or a landing page with no resolvable file at all.
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "paper",
            url: "https://example.com/paper.pdf",
            isPDF: true
        ))
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "paper",
            url: "Papers/123/paper.pdf",
            hasLocalFile: true
        ))
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "paper",
            isWebArticle: false
        ))
        #expect(!ForeverLMCore.supportsReadTracking(
            sourceType: "book",
            url: "https://example.com/book.epub"
        ))
        #expect(!ForeverLMCore.supportsReadTracking(
            sourceType: "article",
            url: "Web Imports/123/note.txt"
        ))
        #expect(!ForeverLMCore.supportsReadTracking(
            sourceType: "article",
            url: "https://example.com/local-note",
            hasLocalFile: true
        ))
        #expect(ForeverLMCore.supportsReadTracking(
            sourceType: "article",
            url: "https://example.com/archived-note",
            hasLocalFile: true,
            isArchivedArticle: true
        ))
        #expect(!ForeverLMCore.supportsReadTracking(
            sourceType: "manual",
            url: "https://example.com/manual.pdf",
            isPDF: true
        ))
        #expect(!ForeverLMCore.supportsReadTracking(
            sourceType: "article",
            isWebArticle: false
        ))
    }

    @Test("Whole-source review timing is shared and bounded")
    func wholeSourceReviewTiming() {
        #expect(ForeverLMCore.wholeSourceReviewIntervalDays(reviewCount: 1, lastScore: 0.9) == 3.2)
        #expect(ForeverLMCore.wholeSourceReviewIntervalDays(reviewCount: 1, lastScore: 0.7) == 2)
        #expect(ForeverLMCore.wholeSourceReviewIntervalDays(reviewCount: 1, lastScore: 0.2) == 1)
        #expect(ForeverLMCore.wholeSourceReviewIntervalDays(reviewCount: 100_000, lastScore: 1) == 180)
        #expect(ForeverLMCore.wholeSourceReviewDueAtMilliseconds(
            lastReviewedAtMilliseconds: 1_000,
            reviewCount: 2,
            lastScore: nil
        ) == 1_000 + 4.4 * 86_400_000)
        #expect(ForeverLMCore.wholeSourceFirstReviewDueAtMilliseconds(
            consumedAtMilliseconds: 1_000
        ) == 86_401_000.0)
        #expect(ForeverLMCore.wholeSourceReviewDueAtMilliseconds(
            lastReviewedAtMilliseconds: .nan,
            reviewCount: 1,
            lastScore: nil
        ) == nil)
    }

    @Test("Tutor tools are one versioned portable contract")
    func tutorContract() throws {
        let tools = TutorContract.tools(
            includeWholeSourceReviewQueue: true,
            endSessionSupportsGaps: true
        )
        #expect(TutorContract.protocolVersion == 3)
        #expect(Set(tools.map(\.name)) == [
            "get_schedule", "get_review_queue", "search_sources", "log_external_activity", "load_source",
            "show_paper_figure", "get_memory_review_queue", "load_memory_item", "start_memory_review",
            "prepare_review", "record_grade", "end_session",
        ])
        let encoded = try #require(TutorContract.encodedTools(
            includeWholeSourceReviewQueue: true,
            endSessionSupportsGaps: true
        ))
        let decoded = try JSONDecoder().decode([TutorToolDefinition].self, from: Data(encoded.utf8))
        #expect(decoded == tools)
        #expect(decoded.first(where: { $0.name == "end_session" })?.parameters.properties?["gaps"] != nil)
        #expect(TutorContract.reviewPreparationInstructions.contains("REVIEW QUESTIONS AND ANSWER GUIDES"))
    }

    @Test("AI task Settings metadata is one complete ordered catalog")
    func aiTaskSettingsCatalog() throws {
        let expectedIDs = [
            "chat", "review_grading",
            "realtime_review_preparation", "mobile_review", "mobile_voice_agent",
            "deep_research", "source_discovery", "chat_title", "chat_history_compaction", "transcript_formatting",
            "podcast_speaker_identification", "podcast_youtube_matching", "slide_frame_classification",
            "slide_citation_extraction", "paper_figure_understanding",
            "lecture_paper_discovery", "meeting_paper_discovery", "paper_reference_extraction", "article_link_discovery",
            "journal_article_matching",
            "citation_resolution", "embedding",
            "source_classification", "paper_metadata", "paper_narration_preparation",
            "paper_read_aloud_preparation", "automatic_audio_filtering",
            "paper_attachment_check", "paper_browser_agent",
            "article_metadata", "article_chrome_filtering", "book_author",
            "duplicate_detection", "topic_summarization",
            "book_chapter_splitting", "scanned_page_proofreading", "meeting_session_details", "meeting_action_items", "lecture_note_matching",
            "course_ordering", "course_metadata", "course_lecture_naming",
            "cohort_session_plan", "source_idea_extraction",
            "card_drafting", "card_go_deeper", "card_answer_check", "card_wording_check", "mnemonic_reading_writing", "notebook_naming", "pasted_line_joining", "map_summaries", "canvas_ask", "canvas_voice", "atlas_writing", "source_levels",
            "course_curriculum_plan", "course_lesson_writing",
            "explainer_writing", "audio_overview_writing", "report_writing",
            "walkthrough_writing", "walkthrough_animation",
            "lecture_quiz_writing", "course_quiz_writing", "course_textbook_readings",
        ]
        let tasks = AITaskSettingsCatalog.tasks

        #expect(AITaskSettingsCatalog.version == 41)
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "video_quiz_grading") == nil)
        #expect(tasks.map(\.id) == expectedIDs)
        #expect(Set(tasks.map(\.id)).count == tasks.count)
        #expect(tasks.allSatisfy { !$0.displayName.isEmpty && !$0.description.isEmpty })
        #expect(Set(tasks.filter { $0.modelDefault == .chat }.map(\.id)) == [
            "chat", "deep_research", "source_discovery",
            "card_go_deeper", "card_answer_check", "canvas_ask", "atlas_writing",
        ])
        #expect(Set(tasks.filter(\.requiresVision).map(\.id)) == [
            "slide_frame_classification", "slide_citation_extraction", "paper_figure_understanding",
            "scanned_page_proofreading",
        ])
        #expect(Set(tasks.filter { $0.modelDefault == .backgroundMultimodal }.map(\.id)) == [
            "slide_frame_classification", "slide_citation_extraction", "paper_figure_understanding",
            "scanned_page_proofreading",
        ])
        #expect(tasks.allSatisfy {
            ($0.modelDefault == .backgroundMultimodal) == $0.requiresVision
        })
        #expect(Set(tasks.filter { !$0.showInAdvancedSettings }.map(\.id)) == [
            "chat", "deep_research", "source_discovery", "embedding",
        ])
        #expect(AITaskSettingsCatalog.advancedTasks.map(\.id)
            == tasks.filter(\.showInAdvancedSettings).map(\.id))
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "paper_metadata")?.displayName
            == "Paper Metadata")
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "missing") == nil)

        let encoded = try #require(AITaskSettingsCatalog.encodedTasks())
        let decoded = try JSONDecoder().decode(
            [AITaskSettingsDescriptor].self,
            from: Data(encoded.utf8)
        )
        #expect(decoded == tasks)
    }
}
