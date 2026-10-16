import Foundation

/// Sources the learner brought into a chat between two of their messages.
///
/// Dropping three articles onto a running chat and asking "explain the
/// takeaways from these articles" is one gesture in two parts, and only the
/// second half used to survive: the composer's "9 in context" chip moved on,
/// and a reopened transcript showed a question about "these articles" with no
/// trace of which articles had just arrived (product owner, 2026-09-12). The
/// additions now ride beside the next message the learner sends, as a mark on
/// the first line of the exchange's `context_content` — the model-only column
/// that already carries a quoted passage, the plugin mark
/// (`ChatPluginRequest`) and the side-question mark (`ChatSideQuestion`) — so
/// the transcript draws "Added 3 articles to context" above that message,
/// reloads it, and syncs it to the other Mac and the web Studio.
///
/// The mark is a record of what the learner did, not the sources themselves:
/// the text was read into the prompt the moment it was dropped
/// (`ReviewSessionManager.addContextSources`), and the ordered set the chat
/// holds is `review_sessions.loaded_source_ids`. What the mark adds is *when*,
/// and it carries each source's title and type so a transcript can be drawn
/// without the library — a source deleted since still reads by name.
///
/// The same mark records what the chat's window showed when the message was
/// sent (`onScreen`). A learner with a paper attached to a chat and an article
/// open in the Reader beside it asked "do you see the article I have open?",
/// and the tutor named the attached paper (product owner, 2026-09-24): what was
/// attached settled it, so it never looked at the window. The sources on
/// screen in the chat's window now ride beside every message, so "this
/// article" resolves without a tool call, and the record says what the
/// learner was looking at when they asked. It draws nothing in the transcript.
///
/// Foundation only, like the two marks it sits above, so every client reads
/// the same line. Its line goes first, ahead of the plugin mark; the other two
/// parsers skip it, so a call site that never heard of additions sees exactly
/// what it saw before.
enum ChatContextAdditions {

    /// One source as the mark names it. `type` is the `StudioSourceType` raw
    /// value as stored, kept a string so a type this build does not know
    /// still reads back and counts as a source.
    struct Source: Codable, Equatable, Hashable, Sendable {
        var id: String
        var title: String
        var type: String

        init(id: String, title: String, type: String) {
            self.id = id
            self.title = title
            self.type = type
        }
    }

    /// A library source on screen in the chat's window as the message went.
    /// `kind` is the word the window's own listing uses ("paper", "book
    /// chapter"), from `ChatOpenPanes`. `moment` is where a video on screen
    /// stood; nil for everything that is not a playing or paused video.
    struct OnScreen: Codable, Equatable, Hashable, Sendable {
        var id: String
        var title: String
        var kind: String
        var moment: VideoMoment?

        init(id: String, title: String, kind: String, moment: VideoMoment? = nil) {
            self.id = id
            self.title = title
            self.kind = kind
            self.moment = moment
        }
    }

    /// The flashcard the Memory pane beside the chat had in front of the
    /// learner as the message went: its To Check card, the one "this
    /// question" or "it" means (product owner, 2026-10-15: "whatever is open
    /// on the right is actually automatically in the chat context"). It rides
    /// beside every message like the sources on screen do, and carries the
    /// whole card so the tutor never needs a tool call to read it.
    struct CardOnScreen: Codable, Equatable, Hashable, Sendable {
        var id: String
        var question: String
        var answer: String
        /// Why the answer is right, one line per reason; empty when there is none.
        var why: [String]
        var sourceID: String?
        var sourceTitle: String?
        /// The pane's section and the card's place in it: "To Check, 1 of 170".
        var place: String
        /// Whether the learner had turned the card over, so the tutor does not
        /// give away an answer the card is still asking for.
        var answerShown: Bool
        /// The pictures on the card's question and answer as Markdown image
        /// lines, so a chat that adds one sends the whole list `update_card`
        /// replaces. Nil when the card shows none, which leaves a stored
        /// message's bytes as they were.
        var frontImages: [String]?
        var backImages: [String]?

        init(
            id: String,
            question: String,
            answer: String,
            why: [String] = [],
            sourceID: String? = nil,
            sourceTitle: String? = nil,
            place: String,
            answerShown: Bool,
            frontImages: [String]? = nil,
            backImages: [String]? = nil
        ) {
            self.id = id
            self.question = question
            self.answer = answer
            self.why = why
            self.sourceID = sourceID
            self.sourceTitle = sourceTitle
            self.place = place
            self.answerShown = answerShown
            self.frontImages = frontImages?.isEmpty == false ? frontImages : nil
            self.backImages = backImages?.isEmpty == false ? backImages : nil
        }
    }

    /// Where a video beside the chat stood when the learner asked.
    ///
    /// The product owner (2026-09-29), of a talk full of physics he wanted to stop and
    /// ask about: the assistant "should also be able to just look at the
    /// screen that is active then and there and transcript around there". The
    /// chat knew which video was open and nothing about where in it the
    /// learner was, so a question about "this slide" meant nothing until they
    /// typed the time out. `at` and `playing` are stamped from the Reader's
    /// playhead as the message goes; `said` and `frame` are filled in by the
    /// send before the turn starts (`ReviewSessionManager.completeVideoMoments`),
    /// and all four are stored with the message, so a replayed history says
    /// exactly what the first request said. Every field but `at` is optional
    /// and left out of the JSON when nil, so a mark without a moment keeps its
    /// bytes.
    struct VideoMoment: Codable, Equatable, Hashable, Sendable {
        /// The playhead, in whole seconds from the start.
        var at: Int
        /// False while the player was paused; nil when the Reader did not say.
        var playing: Bool?
        /// The transcript around `at`, one `[m:ss] words` line per segment.
        var said: String?
        /// True when the frame on screen at `at` was captured on this Mac and
        /// goes to the model with the message as a picture.
        var frame: Bool?

        init(at: Int, playing: Bool? = nil, said: String? = nil, frame: Bool? = nil) {
            self.at = max(0, at)
            self.playing = playing
            self.said = said
            self.frame = frame
        }

        /// "26:51", or "1:02:03" past the hour.
        var clock: String { ChatContextAdditions.clock(at) }

        /// The picture of the moment, `foreverlm://image/<id>/at/<seconds>`,
        /// as `show_source_image` hands it out.
        func frameReference(sourceID: String) -> SourceImageReference {
            SourceImageReference(sourceID: sourceID, location: .moment(at))
        }
    }

    /// Persisted in `context_content` rows and synced, so the stored tag
    /// keeps its original spelling.
    static let tagName = "flm_context_sources"

    private static let openingTag = "<\(tagName)>"
    private static let closingTag = "</\(tagName)>"

    /// `added` is always written, empty or not, so a build that knows only
    /// additions still reads a mark that carries only `onScreen`; `onScreen`
    /// is left out when empty, so a mark of additions alone keeps its bytes.
    private struct Payload: Codable {
        var added: [Source]
        var onScreen: [OnScreen]?
        var card: CardOnScreen?
    }

    /// The one-line mark for these additions and on-screen sources, or nil
    /// when there is nothing to mark. The payload is JSON on one line —
    /// `JSONEncoder` escapes any newline inside a title — with sorted keys,
    /// so the same additions always produce the same bytes.
    static func marker(added: [Source], onScreen: [OnScreen] = [], card: CardOnScreen? = nil) -> String? {
        let additions = dedupe(added)
        let shown = dedupe(onScreen)
        guard !additions.isEmpty || !shown.isEmpty || card != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = Payload(added: additions, onScreen: shown.isEmpty ? nil : shown, card: card)
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return openingTag + json + closingTag
    }

    // MARK: - The mark on a message

    /// What a message stores when sources joined the chat before it: the
    /// mark, over whatever the message carried anyway — a plugin mark, a side
    /// question, a quoted passage. Nothing to mark hands the reference
    /// material back unchanged.
    static func contextContent(
        added: [Source],
        onScreen: [OnScreen] = [],
        card: CardOnScreen? = nil,
        referenceContext: String?
    ) -> String? {
        let reference = referenceContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = marker(added: added, onScreen: onScreen, card: card) else {
            return reference?.isEmpty == false ? reference : nil
        }
        guard let reference, !reference.isEmpty else { return mark }
        return mark + "\n" + reference
    }

    /// The stored context with the sources on screen written into its mark,
    /// beside any additions already there. Nothing on screen hands the
    /// context back unchanged.
    static func contextContent(_ contextContent: String?, onScreen: [OnScreen], card: CardOnScreen? = nil) -> String? {
        guard !dedupe(onScreen).isEmpty || card != nil else { return contextContent }
        let stored = parse(contextContent: contextContent)
        return self.contextContent(added: stored.added, onScreen: onScreen, card: card, referenceContext: stored.remainder)
    }

    /// The stored context with each on-screen video's moment replaced by the
    /// one `moments` holds for it — the transcript and the frame filled in
    /// once the message is on its way. A source with no entry keeps what it
    /// had, and a context with nothing on screen comes back unchanged.
    static func contextContent(_ contextContent: String?, completingMoments moments: [String: VideoMoment]) -> String? {
        guard !moments.isEmpty else { return contextContent }
        let stored = parse(contextContent: contextContent)
        guard stored.onScreen.contains(where: { moments[$0.id] != nil }) else { return contextContent }
        let completed = stored.onScreen.map { source -> OnScreen in
            var source = source
            if let moment = moments[source.id] { source.moment = moment }
            return source
        }
        return self.contextContent(added: stored.added, onScreen: completed, card: stored.card, referenceContext: stored.remainder)
    }

    /// A message's stored context, read back: the sources that joined before
    /// it, what was on screen, and what is left once the mark is taken off. A context that never
    /// carried the mark comes back whole as `remainder`, and so does one whose
    /// mark cannot be read, so the parsers downstream see what they always saw.
    struct Parsed: Equatable, Sendable {
        var added: [Source]
        var onScreen: [OnScreen] = []
        var card: CardOnScreen? = nil
        var remainder: String?
    }

    static func parse(contextContent: String?) -> Parsed {
        guard let content = contextContent?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            return Parsed(added: [], remainder: nil)
        }
        let firstLineEnd = content.firstIndex(where: \.isNewline) ?? content.endIndex
        let firstLine = String(content[..<firstLineEnd])
        guard firstLine.hasPrefix(openingTag), firstLine.hasSuffix(closingTag),
              firstLine.count > openingTag.count + closingTag.count else {
            return Parsed(added: [], remainder: content)
        }
        let json = firstLine.dropFirst(openingTag.count).dropLast(closingTag.count)
        guard let data = String(json).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Parsed(added: [], remainder: content)
        }
        let rest = String(content[firstLineEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(
            added: dedupe(payload.added),
            onScreen: dedupe(payload.onScreen ?? []),
            card: payload.card,
            remainder: rest.isEmpty ? nil : rest
        )
    }

    /// The stored context without the mark: what the other parsers read.
    static func stripping(contextContent: String?) -> String? {
        parse(contextContent: contextContent).remainder
    }

    // MARK: - What the transcript says

    /// The row's one line: "Added 3 articles to context". The noun is the
    /// sources' own kind when they share one, and "sources" when they do not.
    static func summary(added: [Source]) -> String {
        let additions = dedupe(added)
        guard !additions.isEmpty else { return "" }
        return "Added \(countedNoun(for: additions)) to context"
    }

    /// "3 articles", "1 paper", "2 sources".
    static func countedNoun(for added: [Source]) -> String {
        let additions = dedupe(added)
        let count = additions.count
        let kinds = Set(additions.map { family(of: $0.type) })
        let noun: String
        if kinds.count == 1, let kind = kinds.first {
            noun = count == 1 ? kind.singular : kind.plural
        } else {
            noun = count == 1 ? "source" : "sources"
        }
        return "\(count) \(noun)"
    }

    // MARK: - What the model is told

    /// Appended to the learner's turn, outside the reference wrapper, so the
    /// model knows what "these articles" points at: the sources whose text it
    /// was handed just before this message, by title.
    static func framing(added: [Source]) -> String? {
        let additions = dedupe(added)
        guard !additions.isEmpty else { return nil }
        let names = additions.map { "“\($0.title.trimmingCharacters(in: .whitespacesAndNewlines))”" }
        return "<context_sources_added>\nJust before this message the learner added "
            + countedNoun(for: additions)
            + " to this chat's context, whose text is now in your source material: "
            + names.joined(separator: "; ")
            + ". \"These\" or \"the new\" sources in the message means them.\n</context_sources_added>"
    }

    /// Appended to the learner's turn beside the additions framing: the
    /// sources on screen in the chat's window as the message went, by title
    /// and source_id, so "this article" or "what I have open" means them and
    /// not whatever happens to be attached.
    static func onScreenFraming(_ onScreen: [OnScreen]) -> String? {
        let shown = dedupe(onScreen)
        guard !shown.isEmpty else { return nil }
        let names = shown.map { source in
            "\(source.kind) “\(source.title.trimmingCharacters(in: .whitespacesAndNewlines))” (source_id: \(source.id))"
                + (source.moment.map { ", " + playheadPhrase($0) } ?? "")
        }
        return "<on_screen_when_sent>\nWhen the learner sent this message, ForeverLM showed "
            + names.joined(separator: "; ")
            + ". \"This article\", \"this paper\", \"what I have open\" or \"what I'm reading\" means what was shown, "
            + "whether or not it is attached to this chat; the chat's attached sources are what the learner gave it, not what they are looking at. "
            + "A shown source that is not attached is still in the library: read it with get_source_content before answering about it. "
            + "Only the latest message's list is what is open now.\n</on_screen_when_sent>"
    }

    /// Appended to the learner's turn beside the on-screen framing: the
    /// flashcard the Memory pane beside the chat had in front of them as the
    /// message went, whole, so "this question is phrased weird" or "why is
    /// that the answer?" means that card without a tool call.
    static func cardFraming(_ card: CardOnScreen?) -> String? {
        guard let card else { return nil }
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines = [
            "<card_on_screen_when_sent>",
            "When the learner sent this message, a Memory pane in ForeverLM (\(card.place)) showed this flashcard (card_id: \(card.id)):",
            "Question: \(clean(card.question))",
            "Answer: \(clean(card.answer))",
        ]
        let reasons = card.why.map(clean).filter { !$0.isEmpty }
        if !reasons.isEmpty { lines.append("Why: " + reasons.joined(separator: " ")) }
        if let title = card.sourceTitle.map(clean), !title.isEmpty {
            lines.append("From the source \u{201C}\(title)\u{201D}" + (card.sourceID.map { " (source_id: \($0))" } ?? "") + ".")
        }
        if let images = card.frontImages { lines.append("Pictures on the question: " + images.joined(separator: " ")) }
        if let images = card.backImages { lines.append("Pictures on the answer: " + images.joined(separator: " ")) }
        lines.append("To put a picture on this card (\"add it to the card\"), call update_card with this card_id and back_images (or front_images), the whole list the face should show: the lines above that stay, then the Markdown image line show_source_image, inspect_paper_figure or generate_image returned for the new one, exactly as returned (![caption](foreverlm://…): a caption lives inside the brackets, never beside the line, and the array holds nothing but those lines). When the learner asks for the picture on a card, do it in that reply: never ask \"would you like me to?\", because they just asked. While the card is still to check this decides nothing: the picture is held with the card, and the learner's Keep carries it. If the learner has kept it since, the same call changes the kept card.")
        lines.append(card.answerShown
            ? "The learner had turned the card over, so the answer was on screen."
            : "The learner had not turned the card over yet: the card was still asking its question, so do not hand over the answer unless they ask for it.")
        lines.append("\"This question\", \"this card\" or \"this answer\" means this card, whether or not any source is attached to this chat. A bare \"this\", \"that\" or \"it\" (\"what does this say exactly?\", \"open that\") is answered from the conversation and the card together: read the turns above for what was just being discussed, read the card for what is open beside the chat, and answer from both. When your previous reply made a claim or cited a source, that is usually what the learner points at, and the card is what they are looking at while they ask; when the two are about the same thing, say so and use both, and when they differ, answer about the reply and mention the card only if it bears on it. Never answer about the card alone as if the earlier turns had not happened. Only the latest message's card is what is open now, but a card named in an earlier message's card_on_screen_when_sent is still reachable by its card_id: when the learner has moved on to another card and asks to add a picture, a fix or a note to \"the previous card\" or \"that card\", it is the card of the earlier message the conversation was about, so call update_card with that card_id, never refuse because the card is no longer beside the chat.")
        lines.append("</card_on_screen_when_sent>")
        return lines.joined(separator: "\n")
    }

    /// Appended beside the on-screen framing for every video the question was
    /// asked at a moment of, once the send filled that moment in: the time,
    /// what was said around it, and the frame on screen then as an image line,
    /// which the turn sends as a picture (`ReviewSessionManager.userTurn`).
    /// Nil when no video on screen carries a filled-in moment.
    static func momentFraming(_ onScreen: [OnScreen]) -> String? {
        let asked = dedupe(onScreen).compactMap { source -> (source: OnScreen, moment: VideoMoment)? in
            guard let moment = source.moment, moment.said != nil || moment.frame != nil else { return nil }
            return (source, moment)
        }
        guard !asked.isEmpty else { return nil }
        let blocks = asked.map { source, moment -> String in
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let clock = moment.clock
            let citation = "[\(title)](foreverlm://source/\(source.id)?t=\(moment.at))"
            let state: String
            switch moment.playing {
            case false?: state = ", with the video paused there"
            case true?: state = ", while it played"
            case nil: state = ""
            }
            var lines = [
                "The learner asked this at \(clock) of the \(source.kind) “\(title)” (source_id: \(source.id))\(state). "
                    + "“This”, “here”, “what was just said”, “this slide” or “this diagram” means that moment unless the learner names another."
            ]
            if let said = moment.said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                lines.append("What was said around it, from the transcript:")
                lines.append(said)
            }
            if moment.frame == true {
                lines.append("What was on screen at \(clock) comes with this message as a picture; read the slide, diagram or equation in it before you answer:")
                lines.append(moment.frameReference(sourceID: source.id).markdown(alt: "\(title) at \(clock)"))
                lines.append("The learner sees that picture beside their message, so show it again only if they ask for it. To point at the moment, cite \(citation).")
            } else {
                lines.append("No picture of the screen at \(clock) could be taken. If the question is about what was on screen, call show_source_image with source_id \(source.id) and at \(moment.at) to see it. To point at the moment, cite \(citation).")
            }
            return lines.joined(separator: "\n")
        }
        return "<video_moment>\n" + blocks.joined(separator: "\n\n") + "\n</video_moment>"
    }

    /// "paused at 26:51", "playing at 26:51", or "at 26:51" when the Reader
    /// did not say which.
    static func playheadPhrase(_ moment: VideoMoment) -> String {
        switch moment.playing {
        case false?: return "paused at \(moment.clock)"
        case true?: return "playing at \(moment.clock)"
        case nil: return "at \(moment.clock)"
        }
    }

    /// The transcript around a moment, as the tutor reads it: the segment
    /// being spoken at `seconds`, and every segment that starts from `before`
    /// seconds ahead of it to `after` seconds past it, one `[m:ss] words` line
    /// each. A question is usually about what was just said, so when the lines
    /// run past `characterLimit` the earliest go first. Nil when no segment is
    /// that close. Segments are taken in the order given, which is the
    /// transcript's.
    static func transcriptExcerpt(
        _ segments: [(seconds: Double, text: String)],
        around seconds: Int,
        before: Double = 90,
        after: Double = 20,
        characterLimit: Int = 2400
    ) -> String? {
        let moment = Double(max(0, seconds))
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            let words = segment.text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !words.isEmpty, segment.seconds.isFinite else { continue }
            // The last segment has no next start; it is under way for two
            // minutes at most, not for the rest of a silent tail.
            let next = index + 1 < segments.count ? segments[index + 1].seconds : segment.seconds + 120
            let spokenAtMoment = segment.seconds <= moment && next > moment
            let nearMoment = segment.seconds >= moment - before && segment.seconds <= moment + after
            guard spokenAtMoment || nearMoment else { continue }
            lines.append("[\(clock(Int(segment.seconds)))] \(words)")
        }
        guard !lines.isEmpty else { return nil }
        while lines.count > 1, lines.joined(separator: "\n").count > characterLimit {
            lines.removeFirst()
        }
        var excerpt = lines.joined(separator: "\n")
        if excerpt.count > characterLimit {
            excerpt = "…" + String(excerpt.suffix(characterLimit))
        }
        return excerpt
    }

    /// "26:51", or "1:02:03" past the hour: the reading a transcript marker and
    /// the player's own clock use.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Helpers

    /// One entry per source id, first mention wins, order kept.
    private static func dedupe(_ added: [Source]) -> [Source] {
        var seen: Set<String> = []
        return added.filter { source in
            let id = source.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted
        }
    }

    private static func dedupe(_ onScreen: [OnScreen]) -> [OnScreen] {
        var seen: Set<String> = []
        return onScreen.filter { source in
            let id = source.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted
        }
    }

    /// How a stored type reads in a sentence. The web-page storage states
    /// fold into "article", the way the Sources sidebar files them.
    private struct Family: Hashable {
        let singular: String
        let plural: String
    }

    private static func family(of rawType: String) -> Family {
        switch rawType {
        case "article", "unclassified", "manual": return Family(singular: "article", plural: "articles")
        case "paper": return Family(singular: "paper", plural: "papers")
        case "podcast": return Family(singular: "podcast", plural: "podcasts")
        case "book": return Family(singular: "book chapter", plural: "book chapters")
        case "course": return Family(singular: "course document", plural: "course documents")
        case "meeting": return Family(singular: "meeting", plural: "meetings")
        case "video": return Family(singular: "video", plural: "videos")
        case "xPost": return Family(singular: "X post", plural: "X posts")
        default: return Family(singular: "source", plural: "sources")
        }
    }
}
