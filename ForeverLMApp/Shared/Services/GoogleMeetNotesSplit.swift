import Foundation

/// Splits a Google Meet "Notes by Gemini" document into the three parts Gemini
/// actually writes: quick notes, full notes, and the verbatim transcript.
///
/// Gemini files one Doc per meeting with three tabs — `✍️ Quick notes`,
/// `📝 Full notes`, `📖 Transcript` — and Drive's `text/plain` export flattens
/// the tabs into a single body, leaving each tab's title behind as a plain
/// line. Everything Google produced is therefore already inside the file this
/// reads. Nothing here fetches and nothing re-derives: the transcript in
/// particular is Google's own, recovered from the export rather than remade
/// from the recording.
///
/// Filing the Doc whole made the transcript invisible — a session showed Notes
/// and Recording and nothing else, so the reader believed it had no transcript,
/// started a paid speech-to-text run on a recording Google had already
/// transcribed, and re-derived text that was sitting in the file the entire
/// time.
///
/// Splitting is deterministic on purpose. These headings are emitted by Google,
/// not written by a person, so there is no reading comprehension to do here —
/// and the result decides which artifact a body of text becomes, which is
/// identity. An LLM belongs on the meaning of a meeting, never on where its
/// transcript begins.
enum GoogleMeetNotesSplit {
    /// One of Gemini's three tabs, named as the export writes it.
    enum Section: CaseIterable {
        case quickNotes
        case fullNotes
        case transcript

        /// The tab title, which the export writes as its heading line.
        var title: String {
            switch self {
            case .quickNotes: return "Quick notes"
            case .fullNotes: return "Full notes"
            case .transcript: return "Transcript"
            }
        }
    }

    struct Result: Equatable {
        /// Gemini's short summary tab.
        let quickNotes: String?
        /// Gemini's detailed tab — the long-form write-up of the same meeting.
        let fullNotes: String?
        /// The transcript tab, with Google's repeated date and
        /// "<meeting> - Transcript" title lines stripped. Nil when the document
        /// carries no transcript section.
        let transcript: String?
        /// Anything above the first Gemini heading. For a document that is not a
        /// Gemini export this holds the whole text, which is what keeps a
        /// hand-written notes file passing through untouched.
        let preamble: String?

        /// Everything belonging to the session's Notes artifact: the preamble
        /// and both notes tabs, each under a Markdown heading.
        ///
        /// Quick and full notes are two distinct things Gemini wrote about the
        /// same meeting — a two-line summary and a page of detail — and the
        /// export separates them only by a line of text. Promoting those lines
        /// to headings keeps both, and keeps them legible as two sections
        /// rather than one undifferentiated wall.
        ///
        /// Nil when the document turned out to be nothing but a transcript.
        var notes: String? {
            var parts: [String] = []
            if let preamble { parts.append(preamble) }
            if let quickNotes { parts.append("### \(Section.quickNotes.title)\n\n\(quickNotes)") }
            if let fullNotes { parts.append("### \(Section.fullNotes.title)\n\n\(fullNotes)") }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
    }

    /// Split `text` into Gemini's sections.
    ///
    /// Returns the text unchanged as `preamble` — and therefore as `notes` —
    /// when the document carries no Gemini headings, so a hand-written notes
    /// file, a Meet export without a transcript, and a non-Meet document all
    /// pass through untouched.
    static func split(_ text: String?) -> Result {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(quickNotes: nil, fullNotes: nil, transcript: nil, preamble: nil)
        }

        // Meet's Docs export is CRLF. Normalize before splitting: separating on
        // the `.newlines` character set treats CR and LF as two separators and
        // yields an empty component between them, which rejoins as a blank line
        // after every single line and double-spaces the whole transcript.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        let headings = self.headings(in: lines)
        guard let first = headings.first else {
            return Result(quickNotes: nil, fullNotes: nil, transcript: nil, preamble: cleaned(text))
        }

        var bodies: [Section: [String]] = [:]
        for (offset, heading) in headings.enumerated() {
            let end = offset + 1 < headings.count ? headings[offset + 1].line : lines.count
            let body = Array(lines[(heading.line + 1)..<end])
            let section = heading.section == .transcript
                ? strippingTranscriptHeader(body)
                : body.joined(separator: "\n")
            // A tab title that appears twice appends rather than replaces, so a
            // Doc someone has pasted a second copy into keeps every word.
            guard let section = cleaned(section) else { continue }
            bodies[heading.section, default: []].append(section)
        }

        func body(_ section: Section) -> String? {
            bodies[section].map { $0.joined(separator: "\n\n") }
        }
        return Result(
            quickNotes: body(.quickNotes),
            fullNotes: body(.fullNotes),
            transcript: body(.transcript),
            preamble: cleaned(lines[..<first.line].joined(separator: "\n"))
        )
    }

    /// The Gemini tab titles present as standalone lines, in document order.
    ///
    /// A title carrying its tab emoji is Google's signature and is trusted on
    /// its own. A bare title is not: "Transcript" alone on a line is something a
    /// person writes too, and treating that as a section marker would cut a
    /// hand-written document in half. Two or more distinct bare titles is the
    /// same export with its emoji stripped — one is a coincidence.
    private static func headings(in lines: [String]) -> [(line: Int, section: Section)] {
        var marked: [(line: Int, section: Section)] = []
        var bare: [(line: Int, section: Section)] = []
        for (index, line) in lines.enumerated() {
            guard let heading = self.heading(in: line) else { continue }
            if heading.isEmojiMarked {
                marked.append((index, heading.section))
            } else {
                bare.append((index, heading.section))
            }
        }
        if marked.isEmpty, Set(bare.map(\.section)).count < 2 { return [] }
        return (marked + bare).sorted { $0.line < $1.line }
    }

    /// Read one line as a tab heading, if it is one.
    ///
    /// The emoji is matched as "a leading run of non-ASCII characters" rather
    /// than by its exact code points, so a variation selector Google adds or
    /// drops cannot turn the transcript back into an unrecognized wall of text.
    /// ASCII punctuation is deliberately not skipped: a `* Transcript` bullet in
    /// someone's own notes is a bullet, not a heading.
    private static func heading(in line: String) -> (section: Section, isEmojiMarked: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let emoji = trimmed.prefix { !$0.isASCII || $0 == " " }
        let title = String(trimmed.dropFirst(emoji.count))
        guard let section = Section.allCases.first(where: {
            title.caseInsensitiveCompare($0.title) == .orderedSame
        }) else { return nil }
        return (section, !emoji.isEmpty)
    }

    /// Drop the two header lines Meet repeats under the marker — the meeting
    /// date and a "<meeting name> - Transcript" title — so the transcript
    /// starts at its first timestamp or first speaker turn.
    ///
    /// Only leading lines are considered, and only until the first line that
    /// looks like transcript content, so a session whose export omits one of
    /// them keeps every word of what was said.
    private static func strippingTranscriptHeader(_ lines: [String]) -> String {
        var index = 0
        var headersDropped = 0
        while index < lines.count, headersDropped < 2 {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                index += 1
                continue
            }
            // A timestamp or a "Speaker: said something" line is the transcript
            // proper; stop before consuming it.
            if isTimestamp(line) || line.contains(": ") { break }
            guard line.hasSuffix("Transcript") || parsesAsDate(line) else { break }
            index += 1
            headersDropped += 1
        }
        return lines[index...].joined(separator: "\n")
    }

    private static func isTimestamp(_ line: String) -> Bool {
        line.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    private static func parsesAsDate(_ line: String) -> Bool {
        line.range(
            of: #"^[A-Z][a-z]{2,8} \d{1,2}, \d{4}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func cleaned(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
