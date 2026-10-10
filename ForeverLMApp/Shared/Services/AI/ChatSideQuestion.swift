import Foundation

/// A side question: something the learner asks while the tutor's question is
/// still waiting for an answer.
///
/// A quiz reads every learner message as an attempt. So a learner who wanted
/// to know what Picard actually saw in patients, halfway through being asked
/// about ROS, either swallowed the question or lost the quiz: the tutor
/// answered the aside and never came back. A side question is the third way.
/// The learner marks the message as an aside, the tutor answers it without
/// grading it or asking anything new, and the app keeps the open question in
/// view so the review resumes where it stopped.
///
/// The mark travels beside the message, never in it: a tag line at the top of
/// the exchange's `context_content`, the model-only column that already
/// carries a quoted passage. That makes an aside survive a reload, sync to the
/// other Mac, and stay out of the words the learner is shown as their own.
/// Foundation only, so the phone and the web core read the same mark.
///
/// Two things widened it (product owner, 2026-09-12: "in codex they have the
/// concept of a side chat and 'more details'; add that too"). A side question
/// may be about any reply, not only the newest while it leaves a question
/// open — an `About the reply:` line names which, and in a chat with nothing
/// open the framing simply keeps the aside beside the conversation. And
/// **More details** is a side question the app writes itself: a second tag
/// line under the marker, the fixed words `More details` as the learner's
/// line, and a framing that asks the tutor to expand the reply it names.
enum ChatSideQuestion {

    static let tagName = "flm_side_question"

    /// The line that marks an exchange as a side question.
    static let marker = "<\(tagName)/>"

    static let moreDetailsTagName = "flm_more_details"

    /// The second tag line on a side question the app wrote itself: the
    /// learner pressed More details on a reply. Always sits under `marker`,
    /// so every reader that knows only the first mark still sees an aside.
    static let moreDetailsMarker = "<\(moreDetailsTagName)/>"

    /// The learner's line on a More details request, as stored and shown. The
    /// learner typed nothing, so nothing is invented for them: the lane draws
    /// this as its heading rather than as a bubble of their words.
    static let moreDetailsQuestion = "More details"

    private static let openQuestionPrefix = "Open question: "
    private static let aboutReplyPrefix = "About the reply: "

    // MARK: - The mark on a message

    /// What a side question stores beside itself: the marker (and the More
    /// details mark under it when the app wrote the aside), the first line
    /// of the reply it is about, the tutor's question that was open when it
    /// was asked (one line each, so the tutor on a reopened chat still knows
    /// what they were), and whatever reference material the message carried
    /// anyway, such as a quoted passage.
    static func contextContent(
        openQuestion: String?,
        aboutReply: String? = nil,
        moreDetails: Bool = false,
        referenceContext: String? = nil
    ) -> String {
        var lines = [marker]
        if moreDetails {
            lines.append(moreDetailsMarker)
        }
        if let reply = aboutReply.map(plainLine), !reply.isEmpty {
            lines.append(aboutReplyPrefix + reply)
        }
        if let question = openQuestion.map(plainLine), !question.isEmpty {
            lines.append(openQuestionPrefix + question)
        }
        if let reference = referenceContext?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty {
            lines.append("")
            lines.append(reference)
        }
        return lines.joined(separator: "\n")
    }

    /// A message's stored context, read back: whether it is a side question, the
    /// question that was open when it was asked, and the reference material left
    /// once the mark is taken off. A context that never carried the mark comes
    /// back whole as `referenceContext`. `isMoreDetails` and `aboutReply` are
    /// the widened mark; a side question from before them reads back with
    /// both empty.
    ///
    /// `guess` is the other mark this layer can hold: a question asked with
    /// the learner's guess first (`ChatGuess`), never a side question.
    struct Parsed: Equatable, Sendable {
        var isSideQuestion: Bool
        var openQuestion: String?
        var referenceContext: String?
        var isMoreDetails: Bool = false
        var aboutReply: String? = nil
        var guess: String? = nil
    }

    static func parse(contextContent: String?) -> Parsed {
        // The sources-added mark (`ChatContextAdditions`) and a skill mark
        // (`ChatSkillRequest`) may sit above the plugin mark and this one;
        // they are skipped here so every reader of a side question sees the
        // context it always saw.
        guard let content = ChatSkillRequest.stripping(contextContent: contextContent), !content.isEmpty else {
            return Parsed(isSideQuestion: false, openQuestion: nil, referenceContext: nil)
        }
        guard content.hasPrefix(marker) else {
            if let guessed = ChatGuess.take(from: content) {
                return Parsed(isSideQuestion: false, openQuestion: nil, referenceContext: guessed.remainder, guess: guessed.guess)
            }
            return Parsed(isSideQuestion: false, openQuestion: nil, referenceContext: content)
        }
        var rest = String(content.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        var openQuestion: String?
        var aboutReply: String?
        var isMoreDetails = false
        // The header lines come in any order; the first line that is none of
        // them starts the reference material.
        while true {
            if rest.hasPrefix(moreDetailsMarker) {
                isMoreDetails = true
                rest = String(rest.dropFirst(moreDetailsMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let taken = takeLine(prefixed: aboutReplyPrefix, from: rest) {
                aboutReply = taken.value
                rest = taken.remainder
            } else if let taken = takeLine(prefixed: openQuestionPrefix, from: rest) {
                openQuestion = taken.value
                rest = taken.remainder
            } else {
                break
            }
        }
        return Parsed(
            isSideQuestion: true,
            openQuestion: openQuestion,
            referenceContext: rest.isEmpty ? nil : rest,
            isMoreDetails: isMoreDetails,
            aboutReply: aboutReply
        )
    }

    /// The rest of the first line after `prefix`, and the text after that
    /// line; nil when the text does not start with the prefix. An empty value
    /// reads as nil, the line consumed all the same.
    private static func takeLine(prefixed prefix: String, from text: String) -> (value: String?, remainder: String)? {
        guard text.hasPrefix(prefix) else { return nil }
        let afterPrefix = text.dropFirst(prefix.count)
        let lineEnd = afterPrefix.firstIndex(where: \.isNewline) ?? afterPrefix.endIndex
        let value = afterPrefix[..<lineEnd].trimmingCharacters(in: .whitespaces)
        let remainder = afterPrefix[lineEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (value.isEmpty ? nil : value, remainder)
    }

    static func isSideQuestion(contextContent: String?) -> Bool {
        parse(contextContent: contextContent).isSideQuestion
    }

    static func isMoreDetails(contextContent: String?) -> Bool {
        parse(contextContent: contextContent).isMoreDetails
    }

    // MARK: - The reply an aside is about

    /// The one line that names a tutor reply: its first paragraph, in plain
    /// text, cut to a length that still reads as a line. Stored beside an
    /// aside about that reply and matched against the transcript when the
    /// chat is drawn, so both sides must come through here.
    static func replyLine(in assistantText: String) -> String? {
        let first = assistantText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let first else { return nil }
        let plain = plainLine(first)
        guard !plain.isEmpty else { return nil }
        guard plain.count > replyLineLimit else { return plain }
        return String(plain.prefix(replyLineLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let replyLineLimit = 160

    // MARK: - The open question

    /// The question a tutor reply leaves waiting: its last paragraph, when that
    /// paragraph asks something. A reply that ends in a statement leaves
    /// nothing open. The result is plain text — the markdown emphasis a tutor
    /// puts on a term is not something to pin above a composer.
    static func openQuestion(in assistantText: String) -> String? {
        let paragraphs = assistantText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return nil }
        let plain = plainLine(last)
        guard plain.hasSuffix("?") else { return nil }
        return plain
    }

    /// One line of plain text out of a line of light markdown: emphasis
    /// markers, inline code ticks, a leading list bullet or heading hashes,
    /// and closing quotation marks after the question mark.
    static func plainLine(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = line.first, "#-*>\"'“‘«".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "__", with: "")
        line = line.replacingOccurrences(of: "`", with: "")
        line = line.replacingOccurrences(of: "*", with: "")
        while let last = line.last, "\"'”’)»".contains(last) {
            line.removeLast()
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - What the tutor is told

    /// Appended to the side question itself, on the way to the model. The
    /// learner never sees it. It stands outside the reference-material wrapper
    /// on purpose: that wrapper tells the model to follow nothing it contains.
    ///
    /// Three shapes. A More details press asks for the named reply to be
    /// expanded. A side question while a question is open is answered on a
    /// short leash: nothing graded, nothing new asked, and the open question's
    /// answer kept back. A side question with nothing open drops that last
    /// clause and simply stays beside the conversation. Whichever reply the
    /// aside is about is named by its first line when one was stored.
    static func framing(openQuestion: String?, aboutReply: String? = nil, moreDetails: Bool = false) -> String {
        let question = openQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let reply = aboutReply?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let whichReply = reply.map { " — the one that begins “\($0)”" } ?? ""

        var lines: [String] = []
        if moreDetails {
            lines.append("<more_details>")
            lines.append(
                "The learner pressed More details on one of your replies\(whichReply). Their message above is that "
                    + "press, not words they typed. Expand that reply as their tutor: the mechanism behind what it "
                    + "says, a worked example or two, the caveats, and where in their sources they can read on, with "
                    + "the source named. Stay with what that reply covers rather than moving the conversation forward, "
                    + "and do not repeat the reply itself."
            )
            lines.append(
                "This is not an attempt at any question — do not grade it, do not score or mark ideas as recalled, "
                    + "and do not ask a new review question of your own."
            )
        } else if question != nil {
            lines.append("<side_question>")
            lines.append(
                "The learner's message above is a side question, asked while your question was still open"
                    + (reply == nil ? ". " : ", about your reply\(whichReply). ")
                    + "Answer it as their tutor: directly, drawing on their library where it helps. "
                    + "It is not an attempt at your question — do not grade it, do not score or mark ideas as recalled, "
                    + "and do not treat it as their answer. Do not ask a new review question of your own, and do not "
                    + "repeat the open question: ForeverLM shows it under your reply and the learner returns to it from there."
            )
        } else {
            lines.append("<side_question>")
            lines.append(
                "The learner's message above is a side question: an aside about your reply\(whichReply), asked "
                    + "beside the conversation rather than as its next step. Answer it as their tutor: directly, "
                    + "drawing on their library where it helps. Do not move the conversation on from it, do not treat "
                    + "it as their answer to anything, and do not ask a review question of your own; the learner "
                    + "picks the thread back up themselves."
            )
        }
        if let question {
            lines.append(
                "The open question is still theirs to answer. Do not give its answer away, in whole or in part, and do "
                    + "not walk up to it by explaining the exact point it tests. If "
                    + (moreDetails ? "part of the reply cannot be expanded" : "the side question cannot be answered")
                    + " without doing that, \(moreDetails ? "expand the rest" : "answer what can be answered"), then say "
                    + "plainly that the remainder is what the open question is asking, and leave it to them."
            )
            lines.append(openQuestionPrefix + question)
        }
        lines.append(moreDetails ? "</more_details>" : "</side_question>")
        return lines.joined(separator: "\n")
    }

    /// Appended to the first ordinary message after a side question, so the
    /// tutor reads it against the question it asked and not against the aside.
    static let closingFraming = """
    <side_question_closed>
    The side question above is settled. Unless this message says otherwise, it is the learner's answer to the \
    question you asked before the side question; read it against that question and carry on from there.
    </side_question_closed>
    """

    /// The closing that fits the aside: `closingFraming` when a question was
    /// open under it, and otherwise a note that the conversation resumes.
    static func closingFraming(openQuestion: String?) -> String {
        if let question = openQuestion?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            return closingFraming
        }
        return """
        <side_question_closed>
        The side question above is settled. This message is the learner picking the conversation back up: read it \
        as their next turn in the conversation, not as more of the aside.
        </side_question_closed>
        """
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A side question lifted out of its quiz into a chat of its own.
///
/// A side question is answered on a short leash: the tutor may not give the
/// quiz's open question away, so a learner who wants to understand the whole
/// of ³¹P-MRS, not just the corner the aside touched, cannot get there in the
/// lane. This is the way out. The aside and every reply it drew go to a new
/// chat as its opening context; the quiz stays exactly where it was, its
/// question still open. The new chat is not the quiz, so nothing is held back
/// there — that is the point of leaving.
struct ChatSideQuestionHandoff: Equatable, Sendable {
    struct Turn: Equatable, Sendable {
        enum Speaker: Equatable, Sendable {
            case learner
            case tutor
        }

        let speaker: Speaker
        let text: String
    }

    /// Where the exchange happened.
    enum Origin: Equatable, Sendable {
        /// In a chat: a side question, or a side chat over one of its replies.
        case chat
        /// In a side chat over words selected in a source in the Reader.
        case reader
    }

    /// The chat the side question was asked in, as its rail row reads; for a
    /// side chat in the Reader, the title of the source it was read in.
    let chatTitle: String
    /// The tutor's question that was open when the aside was asked, if any.
    let openQuestion: String?
    /// The aside, its replies, and any follow-ups, in order.
    let turns: [Turn]
    /// The sources the quiz stood on; the new chat gets the same ones.
    let sourceIDs: [String]
    /// The Notebook the quiz is filed under, so the new chat is filed beside it.
    let notebookID: String?
    var origin: Origin = .chat

    /// What the tutor is told about this context, once, ahead of the learner's
    /// first message here.
    static let framing = """
    The learner asked this as a side question in the middle of a quiz in another chat, and has moved it here \
    to go into it properly. Pick it up where the exchange above leaves off: explain, answer whatever they ask \
    next, and go as deep as they like. This chat is not the quiz, so nothing is held back here — the quiz is \
    still waiting for them in its own chat with its question open, and answering it there is their business. \
    Do not grade them, do not score or mark ideas as recalled, and do not ask review questions of your own.
    """

    /// The same, for a side chat that began over a passage in the Reader:
    /// there was no quiz, only a question about words being read.
    static let readerFraming = """
    The learner asked this in a side chat over a passage they selected while reading, and has moved it here \
    to go into it properly. Pick it up where the exchange above leaves off: explain, answer whatever they ask \
    next, and go as deep as they like. Do not grade them, do not score or mark ideas as recalled, and do not \
    ask review questions of your own.
    """

    /// The one line the pending-context chip shows: the side question's first
    /// line, in plain text. A question that opens with a quoted passage — a
    /// side chat's, which carries the words it was about — is named by the
    /// words the learner typed under the quote, not by the quote.
    var headline: String {
        let asked = turns.first(where: { $0.speaker == .learner })?.text ?? ""
        let lines = asked
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let firstLine = lines.first(where: { !$0.hasPrefix(">") }) ?? lines.first ?? ""
        let plain = ChatSideQuestion.plainLine(firstLine)
        guard plain.isEmpty else { return plain }
        switch origin {
        case .chat: return "A side question from \(chatTitle)"
        case .reader: return "A side chat on \(chatTitle)"
        }
    }

    /// The exchange as the model reads it: labelled turns, in order. A reply
    /// that has not arrived yet is simply not there.
    var transcript: String {
        turns.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let label = turn.speaker == .learner ? "Learner" : "Tutor"
            return "\(label): \(text)"
        }
        .joined(separator: "\n\n")
    }

    /// The block that goes into the new chat's first exchange as its
    /// `context_content`, so the chat still knows what it is about when it is
    /// reopened next month.
    var contextualContent: String {
        if origin == .reader {
            return [
                "From a side chat over a passage of \"\(chatTitle)\" in the Reader:\n\(transcript)",
                Self.readerFraming,
            ].joined(separator: "\n\n")
        }
        var blocks = ["From a side question in the chat \"\(chatTitle)\":\n\(transcript)"]
        if let question = openQuestion?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            blocks.append("The quiz's question that was open when the side question was asked, for orientation only: \(question)")
        }
        blocks.append(Self.framing)
        return blocks.joined(separator: "\n\n")
    }
}
