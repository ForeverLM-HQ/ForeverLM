import Foundation
import Testing
@testable import ForeverLM

/// Google Meet ships one Doc per meeting holding all three of Gemini's tabs —
/// quick notes, full notes, and the verbatim transcript. Until this split
/// existed, that Doc was filed whole as "notes", so a session showed Notes and
/// Recording, the reader concluded it had no transcript, and it started a paid
/// speech-to-text run to reproduce text already in the file.
@Suite("Google Meet Notes Split")
struct GoogleMeetNotesSplitTests {
    /// Shaped exactly like the real export: quick notes, full notes, then the
    /// marker followed by Meet's repeated date and title lines.
    private let meetExport = """
    ✍️ Quick notes
    Acme Longevity Nexus

    Aug 16, 2026
    Research presentation regarding microglial infiltration.

    📝 Full notes
    * Team Updates: Sam Sorensen returned to the group.
    Meeting records Transcript Recording

    📖 Transcript
    Aug 16, 2026
    Acme Longevity Nexus - Transcript
    00:00:01

    Jonas Berg: What? What was that?
    Wade Mercer: Oh, Manhattan.
    Transcription ended after 01:11:50
    """

    @Test("Splits a Meet export into all three of Gemini's tabs")
    func splitsMeetExport() throws {
        let result = GoogleMeetNotesSplit.split(meetExport)

        // Every tab is kept, and each holds only its own body.
        let quick = try #require(result.quickNotes)
        #expect(quick.contains("Research presentation regarding microglial infiltration."))
        #expect(!quick.contains("Team Updates"))

        let full = try #require(result.fullNotes)
        #expect(full.contains("Team Updates: Sam Sorensen returned to the group."))
        #expect(!full.contains("Jonas Berg"))

        let transcript = try #require(result.transcript)
        #expect(transcript.contains("Jonas Berg: What? What was that?"))
        #expect(transcript.contains("Transcription ended after 01:11:50"))
        // Meet's repeated date and title lines are noise above the first turn.
        #expect(!transcript.hasPrefix("Aug 16, 2026"))
        #expect(!transcript.contains("Acme Longevity Nexus - Transcript"))
        #expect(transcript.hasPrefix("00:00:01"))
    }

    @Test("The notes artifact carries both notes tabs, each under its own heading")
    func notesKeepsBothTabs() throws {
        let notes = try #require(GoogleMeetNotesSplit.split(meetExport).notes)

        #expect(notes.contains("### Quick notes"))
        #expect(notes.contains("### Full notes"))
        #expect(notes.contains("Research presentation regarding microglial infiltration."))
        #expect(notes.contains("Team Updates"))
        // The notes half must not keep a copy of what was said.
        #expect(!notes.contains("Jonas Berg: What?"))
        // Quick notes lead, as they do in the Doc.
        let quickHeading = try #require(notes.range(of: "### Quick notes"))
        let fullHeading = try #require(notes.range(of: "### Full notes"))
        #expect(quickHeading.lowerBound < fullHeading.lowerBound)
    }

    @Test("The word 'Transcript' inside the notes is not a section marker")
    func linksLineIsNotAMarker() throws {
        // "Meeting records Transcript Recording" is a links line Meet writes in
        // the middle of the notes. Matching the marker loosely would cut the
        // document there and file most of the notes as transcript.
        let result = GoogleMeetNotesSplit.split(meetExport)
        let full = try #require(result.fullNotes)
        #expect(full.contains("Meeting records Transcript Recording"))
    }

    @Test("An export whose tab titles lost their emoji still splits")
    func splitsWithoutEmoji() throws {
        // Google owns these headings and can restyle them. Two or more bare
        // titles standing alone on their own lines is the same document with the
        // emoji stripped, and losing the transcript to a cosmetic change would
        // send the recording to a paid transcription run.
        let bare = meetExport
            .replacingOccurrences(of: "✍️ ", with: "")
            .replacingOccurrences(of: "📝 ", with: "")
            .replacingOccurrences(of: "📖 ", with: "")
        let result = GoogleMeetNotesSplit.split(bare)

        #expect(result.quickNotes?.contains("microglial infiltration") == true)
        #expect(result.fullNotes?.contains("Team Updates") == true)
        #expect(result.transcript?.hasPrefix("00:00:01") == true)
    }

    @Test("A single bare 'Transcript' line in someone's own notes is not a marker")
    func loneBareTitleIsNotAMarker() throws {
        // One bare title is a coincidence — a heading a person typed. Splitting
        // on it would file the second half of a hand-written document as a
        // verbatim transcript of a meeting.
        let handWritten = """
        Agenda
        * Discuss the paper

        Transcript
        Nobody recorded this one.
        """
        let result = GoogleMeetNotesSplit.split(handWritten)
        #expect(result.transcript == nil)
        #expect(result.notes == handWritten)
    }

    @Test("A document with no transcript section passes through untouched")
    func documentWithoutTranscript() throws {
        let handWritten = "Agenda\n* Discuss the paper\n* Pick a host for next week"
        let result = GoogleMeetNotesSplit.split(handWritten)
        #expect(result.transcript == nil)
        #expect(result.notes == handWritten)
    }

    @Test("Empty and missing input yield nothing rather than empty sections")
    func emptyInput() {
        let nothing = GoogleMeetNotesSplit.Result(
            quickNotes: nil,
            fullNotes: nil,
            transcript: nil,
            preamble: nil
        )
        #expect(GoogleMeetNotesSplit.split(nil) == nothing)
        #expect(GoogleMeetNotesSplit.split("   \n\n ") == nothing)
        #expect(GoogleMeetNotesSplit.split(nil).notes == nil)
    }

    @Test("A CRLF export is split without double-spacing the result")
    func handlesCRLFExports() throws {
        // The real Meet Docs export is CRLF. Splitting on the `.newlines`
        // character set treats CR and LF as separate separators, so every line
        // came back with a blank line glued after it and the transcript read
        // double-spaced. Only real exports catch this — an LF fixture cannot.
        let crlf = meetExport.replacingOccurrences(of: "\n", with: "\r\n")
        let result = GoogleMeetNotesSplit.split(crlf)

        let transcript = try #require(result.transcript)
        #expect(transcript.hasPrefix("00:00:01"))
        #expect(!transcript.contains("\r"))
        #expect(!transcript.contains("\n\n\n"))
        #expect(transcript.contains("Jonas Berg: What? What was that?\nWade Mercer: Oh, Manhattan."))

        // And it agrees exactly with the LF form of the same document.
        #expect(transcript == GoogleMeetNotesSplit.split(meetExport).transcript)
        #expect(result.notes == GoogleMeetNotesSplit.split(meetExport).notes)
    }

    @Test("An export whose transcript omits a header line keeps every spoken word")
    func toleratesMissingHeaderLines() throws {
        let noTitleLine = """
        📝 Full notes
        * A note.

        📖 Transcript
        Aug 16, 2026
        Jonas Berg: First thing said.
        """
        let transcript = try #require(GoogleMeetNotesSplit.split(noTitleLine).transcript)
        #expect(transcript.hasPrefix("Jonas Berg: First thing said."))
    }

    @Test("Import promotes the embedded transcript to its own artifact")
    func importSeparatesEmbeddedTranscript() throws {
        let notes = StudioViewModel.ParsedMeetingArtifact(
            url: URL(string: "https://drive.google.com/file/d/notes-doc")!,
            title: "2026-08-16 - [Notes] - Journal Club",
            sessionKey: "Nexus - 2026/08/16",
            kind: .notes,
            text: meetExport,
            externalURL: nil,
            localFilePath: nil,
            mimeType: nil,
            modifiedAt: nil
        )

        let separated = StudioViewModel.separatingEmbeddedTranscripts(in: [notes])
        #expect(separated.count == 2)

        let transcript = try #require(separated.first { $0.kind == .transcript })
        #expect(transcript.sessionKey == notes.sessionKey, "both halves must land on one session")
        #expect(transcript.text?.contains("Jonas Berg") == true)

        let trimmed = try #require(separated.first { $0.kind == .notes })
        #expect(trimmed.text?.contains("Jonas Berg: What?") == false)
        // Neither notes tab is dropped on the way through import.
        #expect(trimmed.text?.contains("microglial infiltration") == true)
        #expect(trimmed.text?.contains("Team Updates") == true)
    }

    @Test("A standalone transcript file outranks the copy inside the notes")
    func standaloneTranscriptFileWins() throws {
        let session = "Nexus - 2026/08/16"
        let notes = StudioViewModel.ParsedMeetingArtifact(
            url: URL(string: "https://drive.google.com/file/d/notes-doc")!,
            title: "2026-08-16 - [Notes] - Journal Club",
            sessionKey: session,
            kind: .notes,
            text: meetExport,
            externalURL: nil,
            localFilePath: nil,
            mimeType: nil,
            modifiedAt: nil
        )
        let transcriptFile = StudioViewModel.ParsedMeetingArtifact(
            url: URL(string: "https://drive.google.com/file/d/transcript-doc")!,
            title: "2026-08-16 - [Transcript] - Journal Club",
            sessionKey: session,
            kind: .transcript,
            text: "00:00:01\nJonas Berg: The authoritative copy.",
            externalURL: nil,
            localFilePath: nil,
            mimeType: nil,
            modifiedAt: nil
        )

        let separated = StudioViewModel.separatingEmbeddedTranscripts(in: [notes, transcriptFile])
        // One transcript, and it is the standalone file rather than the
        // recovered copy — never two competing transcripts for one session.
        let transcripts = separated.filter { $0.kind == .transcript }
        #expect(transcripts.count == 1)
        #expect(transcripts.first?.text?.contains("authoritative copy") == true)
        // The redundant copy is still trimmed out of the notes.
        #expect(separated.first { $0.kind == .notes }?.text?.contains("Jonas Berg: What?") == false)
    }

    @Test("ForeverLM does not transcribe meeting recordings unless asked to")
    func ownTranscriptionIsOffByDefault() {
        // The default is the product decision: Google already wrote a transcript
        // into the notes Doc, so the import reads it rather than billing a
        // provider to re-derive it.
        let key = StudioViewModel.meetingOwnTranscriptionEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(!StudioViewModel.isMeetingOwnTranscriptionEnabled)

        UserDefaults.standard.set(true, forKey: key)
        #expect(StudioViewModel.isMeetingOwnTranscriptionEnabled)
    }

    @Test("The own-transcription preference follows the account")
    func ownTranscriptionPreferenceSyncs() {
        // A spending decision made on one Mac must not leave the other Mac
        // transcribing the same meetings.
        #expect(SyncedPreferenceKeys.isSynced(StudioViewModel.meetingOwnTranscriptionEnabledKey))
    }
}
