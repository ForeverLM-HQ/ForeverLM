import Foundation

/// Who a line of a live meeting transcript came from. The Mac hears two
/// streams: its own microphone, and the sound the call plays. It cannot tell
/// the people on the far side apart, so they are one voice.
enum LiveMeetingVoice: String, Codable, Sendable, CaseIterable {
    case me
    case them

    var speakerName: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

/// One finished line of a live transcript, timed from the start of the meeting.
struct LiveMeetingLine: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var voice: LiveMeetingVoice
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// A slide kept while the meeting ran: when it appeared, its picture on disk,
/// and the words read off it on this Mac.
struct LiveMeetingSlide: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var number: Int
    var shownAt: TimeInterval
    var imageURL: URL
    var text: String
}

/// The pure rules of a live transcript: what is kept, and how it reads.
enum LiveMeetingTranscriptRules {

    /// Without headphones the microphone also hears the call, so the far side's
    /// words come back a moment later as the learner's own. A microphone line is
    /// that echo when most of its words were just said on the call's side.
    static let echoWindow: TimeInterval = 8
    static let echoWordShare = 0.7

    static func isEcho(_ line: LiveMeetingLine, recentThem: [LiveMeetingLine]) -> Bool {
        guard line.voice == .me else { return false }
        let words = normalizedWords(line.text)
        guard words.count >= 3 else {
            // A short reply ("yes", "okay, thanks") is the learner's more often
            // than an echo; only an exact repeat counts.
            let mine = words.joined(separator: " ")
            return !mine.isEmpty && recentThem.contains { other in
                abs(other.start - line.start) <= echoWindow
                    && normalizedWords(other.text).joined(separator: " ") == mine
            }
        }
        let heard = Set(recentThem
            .filter { $0.end >= line.start - echoWindow && $0.start <= line.end + echoWindow }
            .flatMap { normalizedWords($0.text) })
        guard !heard.isEmpty else { return false }
        let shared = words.filter { heard.contains($0) }.count
        return Double(shared) / Double(words.count) >= echoWordShare
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The transcript as every meeting transcript in the library reads (Zoom's
    /// caption file folded by `formatZoomCaptionTranscript`): one line a turn,
    /// `[HH:MM:SS] Speaker: words`, at the wall-clock time it was said.
    static func transcriptText(_ lines: [LiveMeetingLine], startedAt: Date, calendar: Calendar = .current) -> String {
        lines
            .sorted { $0.start < $1.start }
            .map { "[\(wallClock(startedAt.addingTimeInterval($0.start), calendar: calendar))] \($0.voice.speakerName): \($0.text)" }
            .joined(separator: "\n")
    }

    /// The transcript as a chat reads it: the same lines, with each slide
    /// where it came on screen, numbered as `show_source_image` takes it.
    static func chatText(
        lines: [LiveMeetingLine],
        slides: [LiveMeetingSlide],
        startedAt: Date,
        calendar: Calendar = .current
    ) -> String {
        enum Entry { case line(LiveMeetingLine), slide(LiveMeetingSlide) }
        let entries: [(TimeInterval, Int, Entry)] =
            lines.map { ($0.start, 1, .line($0)) } + slides.map { ($0.shownAt, 0, .slide($0)) }
        return entries
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { seconds, _, entry in
                let time = wallClock(startedAt.addingTimeInterval(seconds), calendar: calendar)
                switch entry {
                case .line(let line):
                    return "[\(time)] \(line.voice.speakerName): \(line.text)"
                case .slide(let slide):
                    let words = slide.text
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " / ")
                    return "[\(time)] Slide \(slide.number) came on screen: \(words.isEmpty ? "(no words read off it)" : words)"
                }
            }
            .joined(separator: "\n")
    }

    static func wallClock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}

/// The live meeting's text as it is stored and as a chat reads it. Pure, and
/// apart from the recorder, which needs macOS 26.
enum LiveMeetingSessionText {
    /// The session's stored text: its title, the transcript in the library's
    /// meeting shape, and the slides in a recording's slide block.
    static func sessionContent(
        sessionTitle: String,
        lines: [LiveMeetingLine],
        slides: [LiveMeetingSlide],
        startedAt: Date,
        calendar: Calendar = .current
    ) -> String {
        let transcript = LiveMeetingTranscriptRules.transcriptText(lines, startedAt: startedAt, calendar: calendar)
        let base = "# \(sessionTitle)\n\n## Transcript\n\n\(transcript)"
        let ordered = slides.sorted { $0.number < $1.number }
        let frames = ordered.enumerated().map { offset, slide in
            let next = offset + 1 < ordered.count ? ordered[offset + 1].shownAt : nil
            return SlideFrameExtraction.SlideFrame(
                index: slide.number,
                timeSeconds: slide.shownAt,
                windows: [SlideTimeWindow(start: slide.shownAt, end: next)],
                localImagePath: StorageService.relativeSourcePath(slide.imageURL.path)
            )
        }
        return SlideFrameExtraction.appending(frames: frames, to: base).content
    }


    static func chatBlock(
        title: String,
        sourceID: String,
        startedAt: Date,
        endedAt: Date?,
        now: Date,
        lines: [LiveMeetingLine],
        slides: [LiveMeetingSlide],
        hearing: [LiveMeetingVoice: String],
        calendar: Calendar = .current
    ) -> String {
        let began = LiveMeetingTranscriptRules.wallClock(startedAt, calendar: calendar)
        let state: String
        if let endedAt {
            state = "was recorded live on this Mac from \(began) to \(LiveMeetingTranscriptRules.wallClock(endedAt, calendar: calendar)); this is all of it"
        } else {
            let minutes = max(0, Int(now.timeIntervalSince(startedAt) / 60))
            state = "is being recorded live on this Mac: it began at \(began) and is \(minutes) minute\(minutes == 1 ? "" : "s") in now"
        }
        var transcript = LiveMeetingTranscriptRules.chatText(lines: lines, slides: slides, startedAt: startedAt, calendar: calendar)
        if endedAt == nil {
            let still = LiveMeetingVoice.allCases.compactMap { voice in
                hearing[voice].map { "(still speaking) \(voice.speakerName): \($0)" }
            }
            if !still.isEmpty {
                transcript += (transcript.isEmpty ? "" : "\n") + still.joined(separator: "\n")
            }
        }
        if transcript.isEmpty { transcript = "(Nothing has been said yet.)" }
        let slideNote = slides.isEmpty
            ? ""
            : " Each slide is listed where it came on screen, with the words read off it on this Mac; to look at one, call show_source_image with source_id \(sourceID) and its slide number."
        return """
        The meeting "\(title)" \(state). This transcript is newer than the meeting's stored source text and replaces it. "Me" is the learner's own microphone; "Them" is everyone else on the call, whom the Mac cannot tell apart.\(slideNote)
        <live_meeting_transcript>
        \(transcript)
        </live_meeting_transcript>
        """
    }
}
