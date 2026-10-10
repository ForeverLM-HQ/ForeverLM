import Foundation
import Testing
@testable import ForeverLM

@Suite("Meeting Recording Media")
struct MeetingRecordingMediaTests {

    private func artifact(
        kind: MeetingArtifactKind,
        url: String? = nil,
        localFilePath: String? = nil,
        mimeType: String? = nil
    ) -> MeetingArtifact {
        MeetingArtifact(
            sourceId: "session-1",
            groupId: "group-1",
            kind: kind,
            title: "Artifact",
            url: url,
            localFilePath: localFilePath,
            mimeType: mimeType
        )
    }

    @Test("a local recording file plays natively and supports transcript sync")
    func localRecordingFileIsPreferred() {
        let media = MeetingRecordingMedia.resolve(from: [
            artifact(kind: .transcript, localFilePath: "/meetings/standup/transcript.vtt"),
            artifact(
                kind: .recording,
                url: "https://drive.google.com/file/d/abc123/view",
                localFilePath: "/meetings/standup/Recording.mp4"
            )
        ])

        #expect(media == .localFile(URL(fileURLWithPath: "/meetings/standup/Recording.mp4")))
        #expect(media?.supportsTimeSync == true)
    }

    @Test("a Drive-only recording uses authenticated native playback with sync")
    func driveRecordingUsesAuthenticatedPlayback() {
        let media = MeetingRecordingMedia.resolve(from: [
            artifact(kind: .recording, url: "https://drive.google.com/file/d/abc123/view?usp=drivesdk")
        ])

        guard case .googleDrive(let original, let fileID, _, _) = media else {
            Issue.record("Expected googleDrive, got \(String(describing: media))")
            return
        }
        #expect(original.absoluteString == "https://drive.google.com/file/d/abc123/view?usp=drivesdk")
        #expect(fileID == "abc123")
        #expect(media?.supportsTimeSync == true)
    }

    @Test("Drive open links resolve to an authenticated file id")
    func driveOpenLinkResolvesFileID() {
        let media = MeetingRecordingMedia.resolve(from: [
            artifact(kind: .recording, url: "https://drive.google.com/open?id=abc123")
        ])

        guard case .googleDrive(_, let fileID, _, _) = media else {
            Issue.record("Expected googleDrive, got \(String(describing: media))")
            return
        }
        #expect(fileID == "abc123")
    }

    @Test("non-Google remote recordings are not embedded")
    func nonGoogleRemoteRecordingIsNotPlayable() {
        let media = MeetingRecordingMedia.resolve(from: [
            artifact(kind: .recording, url: "https://example.com/recording.mp4")
        ])

        #expect(media == nil)
    }

    /// A camera-off Zoom call converts to `audio1234.m4a` and nothing else. The
    /// video pane drew QuickTime's audio glyph over a black box for every such
    /// standup; the session is transcript-only as far as the reader is concerned.
    @Test("an audio-only recording is not playable media")
    func audioOnlyRecordingHasNoMedia() {
        let zoom = artifact(
            kind: .recording,
            localFilePath: "/Zoom/2026-09-21 08.32.51 Robin __ Zara/audio1785357466.m4a",
            mimeType: "audio/mp4"
        )
        #expect(MeetingRecordingMedia.isAudioOnly(zoom))
        #expect(MeetingRecordingMedia.resolve(from: [artifact(kind: .transcript), zoom]) == nil)

        // No MIME type recorded: the extension decides.
        let untyped = artifact(kind: .recording, localFilePath: "/Zoom/standup/audio1.m4a")
        #expect(MeetingRecordingMedia.isAudioOnly(untyped))
        #expect(MeetingRecordingMedia.resolve(from: [untyped]) == nil)

        let drive = artifact(
            kind: .recording,
            url: "https://drive.google.com/file/d/abc123/view",
            mimeType: "audio/mpeg"
        )
        #expect(MeetingRecordingMedia.resolve(from: [drive]) == nil)
    }

    @Test("a video recording beside an audio one is still played")
    func videoRecordingIsPreferredOverAudio() {
        let media = MeetingRecordingMedia.resolve(from: [
            artifact(kind: .recording, localFilePath: "/Zoom/standup/audio1.m4a", mimeType: "audio/mp4"),
            artifact(kind: .recording, localFilePath: "/Zoom/standup/video1.mp4", mimeType: "video/mp4")
        ])

        #expect(media == .localFile(URL(fileURLWithPath: "/Zoom/standup/video1.mp4")))
        #expect(!MeetingRecordingMedia.isAudioOnly(
            artifact(kind: .recording, localFilePath: "/meetings/standup/Recording.mp4")
        ))
        // A typed video wins over a misleading extension, and an untyped Drive
        // link with no extension is treated as video, as before.
        #expect(!MeetingRecordingMedia.isAudioOnly(
            artifact(kind: .recording, localFilePath: "/meetings/standup/Recording.m4a", mimeType: "video/mp4")
        ))
        #expect(!MeetingRecordingMedia.isAudioOnly(
            artifact(kind: .recording, url: "https://drive.google.com/file/d/abc123/view")
        ))
    }

    @Test("sessions without recording artifacts have no playable media")
    func transcriptOnlySessionHasNoMedia() {
        let media = MeetingRecordingMedia.resolve(from: [
            artifact(kind: .transcript, localFilePath: "/meetings/standup/transcript.txt"),
            artifact(kind: .notes, url: "https://drive.google.com/file/d/notes1/view")
        ])

        #expect(media == nil)
        #expect(MeetingRecordingMedia.resolve(from: []) == nil)
    }

    @Test("generated transcripts merge before notes without deleting them")
    func generatedTranscriptPreservesNotes() {
        let notes = "# Weekly Sync\n\n## Notes\n\nKeep this summary."
        let merged = MeetingContent.inserting(
            section: .transcript,
            text: "Speaker: Keep this transcript.",
            into: notes,
            title: "Weekly Sync"
        )

        #expect(MeetingContent.contains(section: .transcript, in: merged))
        #expect(merged.contains("Keep this summary."))
        #expect(merged.range(of: "## Transcript")!.lowerBound < merged.range(of: "## Notes")!.lowerBound)
    }

    /// A captured deck is appended to the meeting's stored text, so the reader has to take it
    /// back off before parsing speaker turns. Without the split, every slide's `Image:` line
    /// renders as a paragraph of the transcript and no frame ever reaches the margin.
    @Test("captured slides split out of a meeting's transcript text")
    func slidesSplitOutOfMeetingTranscript() {
        let stored = """
        # Nexus Session

        ## Transcript

        00:03:28

        Grant Fairlow: Still unsolved.

        ## Extracted video slide frames

        Representative slide screenshots extracted from this video's frames.

        ### Slide frame 1 [1:20–2:05]
        Image: Videos/meeting_1/Slides/slide_001_000080s.jpg
        """

        let split = YouTubeSlideContentParser.parse(stored)

        #expect(split.displaySlides.count == 1)
        #expect(split.displaySlides.first?.windows == [SlideTimeWindow(start: 80, end: 125)])
        #expect(!split.transcriptContent.contains("Image:"))
        #expect(split.transcriptContent.contains("Grant Fairlow: Still unsolved."))
        // The stored blob still reads as a meeting, so appending a deck cannot cost the
        // session its transcript section.
        #expect(MeetingContent.contains(section: .transcript, in: stored))

        let rendered = TranscriptReaderView.normalizedMeetingTranscript(split.transcriptContent)
        #expect(!rendered.contains("Slide frame"))
    }

    /// A meeting is one of the two things the app can read video frames from; a web article
    /// is neither, and must not be offered a "Show slides" button that can only fail.
    @MainActor
    @Test("slide extraction is offered for meetings and YouTube, not for articles")
    func slideExtractionSupportIsScoped() {
        let meeting = StudioArticle(
            url: "https://drive.google.com/file/d/rec1/view",
            title: "Nexus Session",
            sourceType: .meeting
        )
        let lecture = StudioArticle(
            url: "https://www.youtube.com/watch?v=AAAAAAAAAAA",
            title: "Lecture",
            sourceType: .video
        )
        let article = StudioArticle(
            url: "https://example.com/post",
            title: "Blog post",
            sourceType: .article
        )

        #expect(StudioViewModel.supportsSlideExtraction(meeting))
        #expect(StudioViewModel.supportsSlideExtraction(lecture))
        #expect(!StudioViewModel.supportsSlideExtraction(article))
    }
}

/// The toast that closes a sidebar-initiated transcript run. One session and a
/// whole folder land in the same summary, and "nothing happened" — every
/// recording already had a transcript — has to read differently from a failure.
@Suite("Meeting Transcript Run Summary")
struct MeetingTranscriptRunSummaryTests {

    @Test("one recording transcribed names the session")
    func singleGenerated() {
        let summary = StudioViewModel.meetingTranscriptSummary(
            attempted: 1,
            generated: 1,
            alreadyHad: 0,
            failures: 0,
            lastFailure: nil,
            singleTitle: "Journal Club",
            groupTitle: nil
        )

        #expect(summary == "Transcript ready for Journal Club.")
    }

    @Test("a session that already had a transcript is not reported as work done")
    func singleAlreadyTranscribed() {
        let summary = StudioViewModel.meetingTranscriptSummary(
            attempted: 1,
            generated: 0,
            alreadyHad: 1,
            failures: 0,
            lastFailure: nil,
            singleTitle: "Journal Club",
            groupTitle: nil
        )

        #expect(summary == "Journal Club already had a transcript.")
    }

    @Test("a failed session carries the reason it failed")
    func singleFailure() {
        let summary = StudioViewModel.meetingTranscriptSummary(
            attempted: 1,
            generated: 0,
            alreadyHad: 0,
            failures: 1,
            lastFailure: "The recording could not be downloaded.",
            singleTitle: "Journal Club",
            groupTitle: nil
        )

        #expect(summary == "Couldn't transcribe Journal Club: The recording could not be downloaded.")
    }

    @Test("a folder pass counts what it finished against what it tried")
    func groupRun() {
        let summary = StudioViewModel.meetingTranscriptSummary(
            attempted: 41,
            generated: 41,
            alreadyHad: 0,
            failures: 0,
            lastFailure: nil,
            singleTitle: nil,
            groupTitle: "Nexus"
        )

        #expect(summary == "Transcribed 41 of 41 recordings in Nexus.")
    }

    @Test("failures in a folder pass are surfaced, not swallowed by the count")
    func groupRunWithFailures() {
        let summary = StudioViewModel.meetingTranscriptSummary(
            attempted: 5,
            generated: 3,
            alreadyHad: 0,
            failures: 2,
            lastFailure: "No recording.",
            singleTitle: nil,
            groupTitle: "Nexus"
        )

        #expect(summary == "Transcribed 3 of 5 recordings in Nexus. 2 failed — last error: No recording.")
    }
}

/// The toast that closes a meeting import. Every import walks the whole folder,
/// so the number of sessions it touched says nothing about what arrived: a
/// refresh over an already-imported folder of forty-two announced "Imported 42
/// meeting sessions" having imported none of them.
@Suite("Meeting Import Summary")
struct MeetingImportSummaryTests {

    @Test("a first import counts the sessions it brought in")
    func firstImport() {
        #expect(
            StudioViewModel.meetingImportSummary(added: 42, updated: 0)
                == "Imported 42 meeting sessions"
        )
    }

    @Test("one new session reads singular")
    func singleSession() {
        #expect(
            StudioViewModel.meetingImportSummary(added: 1, updated: 0)
                == "Imported 1 meeting session"
        )
    }

    @Test("a refresh that found nothing new does not claim an import")
    func nothingNew() {
        #expect(
            StudioViewModel.meetingImportSummary(added: 0, updated: 0)
                == "No new meeting sessions"
        )
    }

    @Test("sessions whose files changed upstream are updates, not imports")
    func updatesOnly() {
        #expect(
            StudioViewModel.meetingImportSummary(added: 0, updated: 3)
                == "Updated 3 meeting sessions"
        )
    }

    @Test("an import that also refreshed older sessions reports both")
    func importedAndUpdated() {
        #expect(
            StudioViewModel.meetingImportSummary(added: 2, updated: 5)
                == "Imported 2 meeting sessions, updated 5"
        )
    }
}

/// Clicking a session's Transcript/Notes/Chat row scrolls the reader to that
/// part of the merged meeting document. These cover the landmarks the view model
/// hands the reader to scroll by — see `MeetingSectionReaderTarget`.
@Suite("Meeting Section Anchors")
struct MeetingSectionAnchorTests {

    @Test("a Gemini notes section is found by the heading it opens with")
    func notesSectionAnchorsOnItsOwnHeading() {
        let anchors = StudioViewModel.meetingSectionAnchors("""
        ### Quick notes

        Acme Longevity Nexus

        Aug 30, 2026
        """)

        // The `## Notes` heading does not survive into the rendered document —
        // this sub-heading takes its place — so it is what the reader looks for.
        #expect(anchors.subheading == "Quick notes")
        #expect(anchors.paragraph == "Acme Longevity Nexus")
    }

    @Test("a transcript section anchors on its first speaker line, not its clock")
    func transcriptSectionSkipsBareTimestamp() {
        let anchors = StudioViewModel.meetingSectionAnchors("""
        00:00:05


        Morgan Ellery: You're back
        Marcus Lindqvist: Uh, I'm back home.
        """)

        // A line holding nothing but a timestamp identifies nothing, and the
        // reader lifts it into the margin rather than rendering it as text.
        #expect(anchors.subheading == nil)
        #expect(anchors.paragraph == "Morgan Ellery: You're back")
    }

    @Test("a leading timestamp is dropped from the line it shares with speech")
    func inlineTimestampIsNotPartOfTheAnchor() {
        let anchors = StudioViewModel.meetingSectionAnchors("[12:04] Karen Whitlock: so the mutation burden scales with")

        #expect(anchors.paragraph == "Karen Whitlock: so the mutation burden scales with")
    }

    @Test("a section with nothing but headings offers no paragraph to scroll to")
    func headingOnlySectionHasNoParagraph() {
        let anchors = StudioViewModel.meetingSectionAnchors("""
        ## Summary

        ###
        """)

        #expect(anchors.subheading == "Summary")
        #expect(anchors.paragraph == nil)
    }

    @Test("a long opening paragraph is trimmed to a findable anchor")
    func longParagraphIsTrimmed() {
        let line = String(repeating: "somatic mutation ", count: 20)
        let anchors = StudioViewModel.meetingSectionAnchors(line)

        #expect(anchors.paragraph?.count == 120)
        #expect(line.hasPrefix(anchors.paragraph ?? "|"))
    }
}

// MARK: - First paint

/// The meeting reader's first frame. The product owner (2026-09-19), clicking a Zoom standup:
/// "first its transcript doesn't render nicely; but only after a few seconds does it
/// render nicely". The parse that makes the rows ran as a detached task and the plain
/// text stood in until it came back; these pin the inline route that replaced that.
@Suite("Meeting Transcript First Paint")
struct MeetingTranscriptFirstPaintTests {

    /// A Zoom caption transcript as the watcher stores it: one timestamped turn per
    /// block, blank lines between. `turns` of them, about `bytesPerTurn` each.
    static func zoomTranscript(turns: Int, bytesPerTurn: Int = 66) -> String {
        let filler = "so the uptake into mitochondria depends on how negative the potential is"
        return (0..<turns).map { index in
            let seconds = 11 * 3600 + 55 * 60 + 24 + index * 9
            let stamp = String(
                format: "%02d:%02d:%02d",
                seconds / 3600, (seconds % 3600) / 60, seconds % 60
            )
            let body = String(repeating: filler + " ", count: 3).prefix(bytesPerTurn - stamp.count - 1)
            return "\(stamp) \(body)"
        }.joined(separator: "\n\n")
    }

    /// A Read AI / Meet export: one speaker line per turn, single newlines, the shape
    /// of the largest transcripts in the library (a Nexus session is 1,158 such lines).
    static func speakerTranscript(lines: Int, bytesPerLine: Int = 116) -> String {
        let names = ["Robin Vale", "Zara Kim", "Grant Fairlow", "Nadia Kalmendra"]
        let filler = "and that is exactly the assay we should run before the next cohort arrives, "
        return (0..<lines).map { index in
            let speaker = names[index % names.count]
            let body = String(repeating: filler, count: 3).prefix(bytesPerLine - speaker.count - 2)
            return "\(speaker): \(body)"
        }.joined(separator: "\n")
    }

    @MainActor
    @Test("A Zoom standup's rows are there on the first lookup, and the memo keeps them")
    func zoomTranscriptIsRowsOnTheFirstFrame() {
        let content = Self.zoomTranscript(turns: 149)
        let key = TranscriptReaderView.meetingParseKey(
            articleID: "src_first_paint_\(UUID().uuidString)",
            content: content
        )
        #expect(TranscriptParseMemos.meeting[key] == nil)

        let parse = TranscriptReaderView.meetingParse(key: key, content: content)

        let transcript = try? #require(parse?.transcript)
        #expect(transcript?.layout == .sections)
        #expect(transcript?.segments.count == 149)
        #expect(transcript?.segments.first?.startTime == "11:55:24")
        #expect(transcript?.segments.last?.startTime == "12:17:36")
        #expect(parse?.slides.isEmpty == true)
        // The render pass stored what it parsed, so the next frame is a lookup.
        #expect(TranscriptParseMemos.meeting[key]?.transcript.segments.count == 149)
    }

    @Test("The inline parse is the task's parse, deck and all")
    func inlineParseIsTheTaskParse() {
        let stored = Self.zoomTranscript(turns: 12) + """


        ## Extracted video slide frames

        Representative slide screenshots extracted from this video's frames.

        ### Slide frame 1 [1:20–2:05]
        Image: Videos/meeting_1/Slides/slide_001_000080s.jpg
        """

        let parse = TranscriptReaderView.parseMeetingTranscript(stored)

        #expect(parse.slides.count == 1)
        #expect(parse.transcript.segments.count == 12)
        #expect(!parse.transcript.segments.contains { $0.text.contains("Image:") })
        #expect(!parse.transcript.segments.contains { $0.text.contains("Slide frame") })
    }

    /// The standups (8–40 KB in the library) parse inline; a Nexus-sized export
    /// (135 KB, the largest stored) takes the immediate off-main route instead.
    @Test("Every standup parses inline; the largest export in the library goes off-main")
    func limitCoversTheStandups() {
        let standup = Self.zoomTranscript(turns: 149)
        let longStandup = Self.zoomTranscript(turns: 590)
        let nexus = Self.speakerTranscript(lines: 1_158)

        #expect(standup.utf8.count > 9_000 && standup.utf8.count < 11_000)
        #expect(longStandup.utf8.count > 39_000 && longStandup.utf8.count < 41_000)
        #expect(nexus.utf8.count > 130_000 && nexus.utf8.count < 140_000)

        #expect(TranscriptReaderView.parsesMeetingTranscriptInline(standup))
        #expect(TranscriptReaderView.parsesMeetingTranscriptInline(longStandup))
        #expect(!TranscriptReaderView.parsesMeetingTranscriptInline(nexus))
    }

    @MainActor
    @Test("A blob past the limit is not parsed in the render pass, and leaves no memo entry")
    func oversizedBlobWaitsForTheTask() {
        let oversized = Self.speakerTranscript(lines: 2_400)
        let key = TranscriptReaderView.meetingParseKey(
            articleID: "src_first_paint_\(UUID().uuidString)",
            content: oversized
        )

        #expect(TranscriptReaderView.meetingParse(key: key, content: oversized) == nil)
        #expect(TranscriptParseMemos.meeting[key] == nil)
    }

    @Test("The off-main route for a blob past the limit draws the same rows as the inline one")
    func offMainRouteMatchesInline() async {
        let oversized = Self.speakerTranscript(lines: 2_400)

        let inline = TranscriptReaderView.parseMeetingTranscript(oversized)
        let offMain = await TranscriptReaderView.parseMeetingTranscriptOffMain(oversized)

        #expect(offMain.transcript.segments.count == 2_400)
        #expect(offMain.transcript.layout == inline.transcript.layout)
        #expect(offMain.transcript.segments.map(\.text) == inline.transcript.segments.map(\.text))
        #expect(offMain.slides.isEmpty)
    }

    @Test("The memo key is the same on every mount of the same blob, and a new blob is a new key")
    func keyFollowsTheBlob() {
        let content = Self.zoomTranscript(turns: 149)
        let first = TranscriptReaderView.meetingParseKey(articleID: "src_a", content: content)
        let second = TranscriptReaderView.meetingParseKey(articleID: "src_a", content: content)
        let withDeck = TranscriptReaderView.meetingParseKey(
            articleID: "src_a",
            content: content + "\n\n## Extracted video slide frames\n"
        )
        let otherMeeting = TranscriptReaderView.meetingParseKey(articleID: "src_b", content: content)

        #expect(first == second)
        #expect(first != withDeck)
        #expect(first != otherMeeting)
    }
}
