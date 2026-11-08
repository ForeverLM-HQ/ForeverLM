import Foundation

/// The source a voice conversation is about: one paper, article, chapter or
/// episode, with all the text the device holds for it.
struct RealtimeVoiceSource: Equatable, Sendable {
    let id: String
    let title: String
    /// The library's source type ("paper", "article", "podcast", "book", ...).
    let sourceType: String
    /// Authors, venue, year: whatever the library shows under the title.
    let byline: String?
    let text: String
    /// A review guide the Mac prepared for this source, when there is one.
    let reviewGuide: String?
}

/// How the conversation opens. Either way the learner can steer it anywhere.
enum RealtimeVoiceOpening: String, Equatable, Sendable {
    /// "What would you like to talk about?", then follow the learner.
    case talk
    /// Starts with the first question about the source.
    case quiz
}

/// One line of a voice conversation, as it is shown and saved.
struct RealtimeVoiceTurn: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case learner
        case tutor
    }

    let id: String
    let role: Role
    var text: String
    /// The learner talked over this reply; `text` is what had been said.
    var wasInterrupted = false
    var spokenAt = Date()

    /// A learner turn's text: they spoke, and their words are not transcribed
    /// (voice mode runs on the realtime model alone).
    static let spokenMark = "(spoken)"
}

/// A voice conversation as the chat history stores it: one exchange per learner
/// line, with the tutor's reply after it. The tutor's opening is the first
/// exchange's question; a tutor line no learner answered is a question alone.
/// The Mac and the iPhone save voice chats through this one mapping.
struct RealtimeVoiceExchange: Equatable, Sendable {
    var question: String
    var answer: String
    var evaluation: String
    var answeredAt: Date

    static func exchanges(from turns: [RealtimeVoiceTurn]) -> [RealtimeVoiceExchange] {
        var exchanges: [RealtimeVoiceExchange] = []
        var unansweredTutorLines: [String] = []
        var unansweredAt: Date?
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch turn.role {
            case .tutor:
                let line = turn.wasInterrupted ? text + " …" : text
                if let last = exchanges.indices.last, unansweredTutorLines.isEmpty, !exchanges[last].answer.isEmpty {
                    // The reply to the learner's latest line.
                    let joined = exchanges[last].evaluation.isEmpty ? line : exchanges[last].evaluation + "\n\n" + line
                    exchanges[last].evaluation = joined
                } else {
                    unansweredTutorLines.append(line)
                    if unansweredAt == nil { unansweredAt = turn.spokenAt }
                }
            case .learner:
                exchanges.append(RealtimeVoiceExchange(
                    question: unansweredTutorLines.joined(separator: "\n\n"),
                    answer: text,
                    evaluation: "",
                    answeredAt: turn.spokenAt
                ))
                unansweredTutorLines = []
                unansweredAt = nil
            }
        }
        if !unansweredTutorLines.isEmpty {
            exchanges.append(RealtimeVoiceExchange(
                question: unansweredTutorLines.joined(separator: "\n\n"),
                answer: "",
                evaluation: "",
                answeredAt: unansweredAt ?? Date()
            ))
        }
        return exchanges
    }

    /// An assistant chat's title: the start of what the learner first asked,
    /// as a typed notebook chat is named by its first question.
    static func assistantChatTitle(firstQuestion: String?) -> String {
        guard let words = firstQuestion?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty,
              words != RealtimeVoiceTurn.spokenMark else {
            return "Voice chat"
        }
        guard words.count > 60 else { return words }
        let cut = words.prefix(60)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }
}

/// The tools a conversation offers the model, answered on the device. A source
/// conversation searches its source; the assistant looks across the library,
/// the plan and the calendar (`MobileRealtimeAssistant`, `MacRealtimeAssistant`).
protocol RealtimeVoiceToolbox: AnyObject, Sendable {
    /// Function definitions in OpenAI Realtime's shape. `end_conversation` is
    /// added by the controller to every conversation.
    var toolDefinitions: [[String: Any]] { get }
    /// The tool's output, as the model reads it (JSON or plain text). Never
    /// throws: a failure is an answer the model can say out loud.
    func run(name: String, argumentsJSON: String) async -> String
    /// The sources the conversation opened, so its chat is filed with them.
    func openedSourceIDs() async -> [String]
}

/// Everything one conversation runs on.
struct RealtimeVoiceBrief: @unchecked Sendable {
    /// What the voice screen is titled.
    let title: String
    let instructions: String
    /// The hidden first learner turn that makes the model speak first.
    let kickoff: String
    let toolbox: RealtimeVoiceToolbox
    /// The one source a source conversation is about; nil for the assistant.
    let source: RealtimeVoiceSource?

    static func source(_ source: RealtimeVoiceSource, opening: RealtimeVoiceOpening) -> RealtimeVoiceBrief {
        RealtimeVoiceBrief(
            title: source.title,
            instructions: RealtimeVoiceTutor.instructions(for: source, opening: opening),
            kickoff: RealtimeVoiceTutor.kickoffMessage(for: opening),
            toolbox: RealtimeVoiceSourceToolbox(source: source),
            source: source
        )
    }
}

/// A source conversation's one tool, passages of its own text, offered only
/// when the source is too long to be in the instructions whole.
final class RealtimeVoiceSourceToolbox: RealtimeVoiceToolbox, @unchecked Sendable {
    private let sourceID: String
    private let passages: [RealtimeVoicePassageSearch.Passage]
    private let fitsInline: Bool

    init(source: RealtimeVoiceSource) {
        sourceID = source.id
        fitsInline = source.text.count <= RealtimeVoiceTutor.inlineTextBudget
        passages = fitsInline ? [] : RealtimeVoicePassageSearch.chunks(of: source.text)
    }

    var toolDefinitions: [[String: Any]] { fitsInline ? [] : [RealtimeVoiceTutor.searchTool] }

    func run(name: String, argumentsJSON: String) async -> String {
        guard name == RealtimeVoiceTutor.searchToolName else { return #"{"error":"Unknown tool."}"# }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        return RealtimeVoicePassageSearch.toolOutput(query: (arguments["query"] as? String) ?? "", passages: passages)
    }

    func openedSourceIDs() async -> [String] { [sourceID] }
}

/// What the realtime model is told, and the tools it may call.
enum RealtimeVoiceTutor {
    /// About 40k tokens of source text go straight into the instructions, well
    /// inside gpt-realtime-2.1's 128k window with room for a long conversation;
    /// the whole session is minted over HTTPS, and OpenAI echoes it back once
    /// over the call's data channel, which carries up to about 256 KB a message.
    /// Longer sources keep their opening there and are searched for the rest.
    static let inlineTextBudget = 150_000
    static let searchToolName = "search_source"
    static let endToolName = "end_conversation"

    static func instructions(for source: RealtimeVoiceSource, opening: RealtimeVoiceOpening) -> String {
        let kind = spokenKind(source.sourceType)
        let fitsInline = source.text.count <= inlineTextBudget
        let text = fitsInline ? source.text : String(source.text.prefix(inlineTextBudget))
        var sections: [String] = []

        sections.append("""
        You are ForeverLM's voice tutor, talking out loud with a learner about one \(kind) they are studying. \
        This is a live spoken conversation, like a phone call with a sharp, warm tutor who has read the \(kind) closely.

        How to talk:
        - Speak naturally and briefly: one to three sentences a turn, then hand the conversation back. \
        Never lecture, never read long passages aloud, never use lists, headings, markdown, URLs or citations by number.
        - Ask one question at a time and wait for the answer.
        - Reply in the language the learner speaks.
        - Say "the \(kind)" or use its title; never "this lecture", "the document" or "the text you provided".
        - If the learner interrupts, drop what you were saying and follow them.

        How to teach (ForeverLM is built on explaining ideas in your own words):
        - When the learner wants to be quizzed, ask questions that make them explain: why something works, what a \
        result means, how two ideas connect, what would change if an assumption failed. Start with the central idea, \
        then go deeper. Mix in the occasional precise recall question (a number, a method, a definition) when it matters.
        - After each answer, say plainly whether it was right, what was missing or mistaken, and the correct idea in a \
        sentence, then ask the next question. Make the next question harder after a good answer and simpler after a miss.
        - When the learner explains something, find the gap in their explanation and ask about it.
        - Ground everything in the \(kind). If it does not say something, say so instead of guessing, and keep outside \
        knowledge clearly labelled as such.
        """)

        if fitsInline {
            sections.append("""
            You have the whole \(kind) below.
            """)
        } else {
            sections.append("""
            Below is the opening of the \(kind); it is too long to include whole. Before you answer or ask about anything \
            beyond it, call \(searchToolName) with a few specific words to read the relevant passages. Say a short \
            "let me check" first so the learner is not left in silence.
            """)
        }

        sections.append("""
        When the learner says goodbye or that they are done, say a one-sentence goodbye and then call \(endToolName).
        """)

        switch opening {
        case .talk:
            sections.append("""
            Opening: greet the learner in one short sentence that names the \(kind), and ask what they would like to \
            talk about or whether they want to be quizzed.
            """)
        case .quiz:
            sections.append("""
            Opening: say in a few words that you'll quiz them on the \(kind), then ask the first question, about its \
            central idea.
            """)
        }

        var header = "Title: \(source.title)"
        if let byline = source.byline?.trimmingCharacters(in: .whitespacesAndNewlines), !byline.isEmpty {
            header += "\nBy: \(byline)"
        }
        sections.append("<source>\n\(header)\n\n\(text)\n</source>")

        if let guide = source.reviewGuide?.trimmingCharacters(in: .whitespacesAndNewlines), !guide.isEmpty {
            sections.append("""
            A review guide prepared for this \(kind), with its key ideas and good questions. Use it to choose what to ask:
            <review_guide>
            \(guide)
            </review_guide>
            """)
        }
        return sections.joined(separator: "\n\n")
    }

    /// The kickoff turn, sent as a hidden learner message so the tutor speaks
    /// first. It is never shown or saved.
    static func kickoffMessage(for opening: RealtimeVoiceOpening) -> String {
        switch opening {
        case .talk: return "(The learner just opened voice mode. Greet them as instructed.)"
        case .quiz: return "(The learner just opened voice mode to be quizzed. Begin as instructed.)"
        }
    }

    static var searchTool: [String: Any] {
        [
            "type": "function",
            "name": searchToolName,
            "description": "Finds the passages of the source that best match a few words, to quote or check it exactly. Returns up to three passages with where they sit in the source.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "A few specific words or a phrase that would appear in the passage.",
                    ],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    static var endTool: [String: Any] {
        [
            "type": "function",
            "name": endToolName,
            "description": "Ends the voice conversation after your goodbye has been spoken. Call it only when the learner says they are done.",
            "parameters": [
                "type": "object",
                "properties": [String: Any](),
            ] as [String: Any],
        ]
    }

    /// The context a replacement call is given after a dropped connection:
    /// what ForeverLM said so far, newest last. The learner's words were never
    /// transcribed, so they are not replayed; `resumeNote` says so.
    static func resumeItems(from transcript: [RealtimeVoiceTurn], limit: Int = 30) -> [(role: String, text: String)] {
        transcript
            .filter { $0.role == .tutor && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(limit)
            .map { (role: "assistant", text: $0.text) }
    }

    /// Sent after `resumeItems`, so the model picks the conversation up.
    static let resumeNote = "(The call dropped and has just reconnected. Above is what you said before it dropped; the learner's replies were spoken and are not shown. In one short sentence, say you're back and ask them to pick up where you left off.)"

    static func spokenKind(_ sourceType: String) -> String {
        switch sourceType.lowercased() {
        case "paper": return "paper"
        case "article", "substack", "blog": return "article"
        case "book", "epub", "chapter": return "chapter"
        case "podcast", "episode": return "episode"
        case "video", "youtube": return "video"
        case "course", "lecture": return "lesson"
        case "meeting": return "meeting"
        default: return "source"
        }
    }
}

/// Finds passages of a source's text for the `search_source` tool. Pure and
/// local: the realtime model asks, the device answers from the text it holds.
enum RealtimeVoicePassageSearch {
    struct Passage: Equatable {
        let text: String
        /// 0...1, where the passage starts in the source.
        let position: Double
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one", "our",
        "out", "has", "had", "how", "its", "who", "did", "get", "may", "new", "now", "see", "two", "way",
        "with", "that", "this", "from", "they", "what", "when", "which", "into", "than", "then", "them",
        "were", "been", "have", "does", "about", "their", "there", "these", "those", "would", "could",
        "should", "where", "while", "paper", "authors",
    ]

    static func chunks(of text: String, size: Int = 1_200, overlap: Int = 200) -> [Passage] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var passages: [Passage] = []
        var start = 0
        while start < characters.count {
            var end = min(characters.count, start + size)
            // End on a sentence or paragraph boundary when one is near.
            if end < characters.count {
                let floor = start + size * 2 / 3
                var cursor = end
                while cursor > floor {
                    let character = characters[cursor - 1]
                    if character == "\n" || character == "." || character == "?" || character == "!" {
                        end = cursor
                        break
                    }
                    cursor -= 1
                }
            }
            let passage = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !passage.isEmpty {
                passages.append(Passage(text: passage, position: Double(start) / Double(characters.count)))
            }
            guard end < characters.count else { break }
            start = max(end - overlap, start + 1)
        }
        return passages
    }

    static func terms(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    static func search(_ query: String, in passages: [Passage], limit: Int = 3) -> [Passage] {
        let queryTerms = terms(query)
        guard !queryTerms.isEmpty else { return [] }
        let phrase = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let scored: [(index: Int, score: Double)] = passages.enumerated().compactMap { index, passage in
            let lower = passage.text.lowercased()
            let words = terms(lower)
            guard !words.isEmpty else { return nil }
            var counts: [String: Int] = [:]
            for word in words { counts[word, default: 0] += 1 }
            var score = 0.0
            var matched = 0
            for term in Set(queryTerms) {
                // A prefix match lets "mitochondrial" find "mitochondria".
                let hits = counts[term] ?? counts.filter { $0.key.hasPrefix(term) || term.hasPrefix($0.key) && $0.key.count > 4 }
                    .values.reduce(0, +)
                if hits > 0 {
                    matched += 1
                    score += 1 + log(Double(hits))
                }
            }
            guard matched > 0 else { return nil }
            score *= Double(matched) / Double(Set(queryTerms).count)
            if phrase.count > 6, lower.contains(phrase) { score += 3 }
            return (index, score)
        }
        return scored
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .prefix(limit)
            .sorted { $0.index < $1.index }
            .map { passages[$0.index] }
    }

    /// The tool's answer, as the model reads it.
    static func toolOutput(query: String, passages: [Passage]) -> String {
        let found = search(query, in: passages)
        guard !found.isEmpty else {
            return #"{"passages":[],"note":"Nothing in the source matches those words. Try other words, or say the source does not cover it."}"#
        }
        let items = found.map { passage -> [String: Any] in
            ["where": "about \(Int((passage.position * 100).rounded()))% of the way through", "text": passage.text]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["passages": items], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"passages":[]}"#
    }
}
