import Foundation

// MARK: - Teach back: the learner says what they know, the tutor fills the holes
//
// A notebook-level chat, started from the notebook's chat beside Quiz me on it
// (docs-site/in-app-chat.md; product owner, 2026-10-11: "add feynman technique
// as one of the things we can do in a notebook ... forcing active recall is
// really important", and 2026-10-17: "it should be at the notebook level",
// "it should just let me explain what i know; and help fill in the holes").
// Where a review is tutor-led (`Prompts.reviewTutor` opens with a plan and
// asks), here the learner leads: the chat opens by asking them what they know
// about the notebook, from memory, and the tutor plays a curious student who
// never explains first, then fills in what is missing
// (`Prompts.teachBackTutor`). The learner-facing name is the feature's own
// (`TeachBack.title`); everything else here keeps a neutral name.

/// What a teach-back chat is known by. The chat's id carries its tutor
/// (`teach-back-<UUID>`), as a course quiz's (`CourseQuizSitting`) and a day's
/// memory review's (`MemoryReviewSession`) do, so a chat reopened on this Mac
/// or another goes on probing: no column records it, and the id syncs with
/// the chat. Web mints and reads the same prefix (`library-teach-back.js`).
enum TeachBack {
    static let sessionIDPrefix = "teach-back-"

    /// The learner-facing name: a deliberate, scoped exception to the retired
    /// method word (product owner, 2026-10-11: "you can call it feynman
    /// technique"). It is the chip's label, help, docs and prompt wording only.
    static let title = "Feynman Technique"

    /// The chat tool a notebook's chat calls when the learner says they want
    /// the Feynman Technique: it opens the teach-back chat once the answer ends.
    static let toolName = "start_feynman_technique"

    /// A new teach-back chat's id.
    static func sessionID(uuid: UUID = UUID()) -> String {
        sessionIDPrefix + uuid.uuidString
    }

    /// Whether a chat is a teach-back, read from its id.
    static func isSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(sessionIDPrefix)
    }

    /// The chat's title: the feature's name and the notebook's.
    static func topic(notebookTitle: String) -> String {
        "\(title): \(notebookTitle)"
    }

    /// The chat's first message, written ahead so no model is asked before
    /// the learner speaks: the notebook named, and the ask to say what they
    /// know of it from memory. Web writes the same words (`teachBackOpening`).
    static func openingMessage(notebookTitle: String) -> String {
        "Tell me what you know about “\(notebookTitle)”, in your own words, from memory, in whatever order it comes. I'll show you pictures from your sources and ask about the gaps."
    }
    // MARK: What you read recently
    //
    // The strip's one-click start (product owner, 2026-11-24: "let me do the
    // Feynman technique on the things that I read yesterday or recently ...
    // a one-button accessible thingy that I can pin maybe in the top left.
    // It should just be a chat"): the same tutor, on the sources the learner
    // read, heard or watched yesterday and today, or in the past week when
    // those two days had none. No notebook.

    /// The days a recent teach-back looks back first, today included, and the
    /// days it widens to when those had nothing.
    static let recentDays = 2
    static let widerRecentDays = 7
    /// At most this many sources, the most recently engaged first: enough
    /// for a day's reading, few enough to pick one from.
    static let recentSourceLimit = 8

    /// The chat's title: the one source's name, or what the sources are.
    static func recentTopic(sourceTitles: [String]) -> String {
        if sourceTitles.count == 1, let only = sourceTitles.first {
            return topic(notebookTitle: only)
        }
        return "\(title): recent reading"
    }

    /// The first message, written ahead as the notebook's is: what the
    /// learner engaged with, named, and the ask to explain one (or all) from
    /// memory. `sinceYesterday` says which window the list came from.
    static func recentOpeningMessage(sourceTitles: [String], sinceYesterday: Bool) -> String {
        let when = sinceYesterday ? "since yesterday" : "this past week"
        if sourceTitles.count == 1, let only = sourceTitles.first {
            return "You spent time with “\(only)” \(when). Tell me what you know about it, in your own words, from memory, in whatever order it comes. I'll show you pictures from it and ask about the gaps."
        }
        let list = sourceTitles.map { "- \($0)" }.joined(separator: "\n")
        return "Here is what you read, heard or watched \(when):\n\n\(list)\n\nPick one, or tie a few together, and tell me what you know about it, in your own words, from memory, in whatever order it comes. I'll show you pictures from your sources and ask about the gaps."
    }
}

// MARK: - Recording an explanation
//
// docs/morning-routine-design.md, "Recording the explanation": the tutor
// says, once the learner has tried, whether an explanation held. It lands on
// the turn's own exchange as `operation` explain (connect for two sources
// tied together), `question_verdict` sound and a score, with the sources in
// `source_refs`; `idea_coverage` stays empty, so the memory review's ladder
// is not told about it. What reads it: the morning's pick.

extension TeachBack {
    /// The tutor's tool. Silent: no activity row, never shown as a score.
    static let recordToolName = "record_explanation"

    /// How far an explanation held, as the tutor judged it.
    enum Verdict: String, CaseIterable, Sendable {
        case held, partial, missing

        /// The exchange's score. The pick counts `held` alone as explained.
        var score: Double {
            switch self {
            case .held: return 1
            case .partial: return 0.5
            case .missing: return 0
            }
        }
    }

    /// The least score the pick reads as explained.
    static let explainedScore = MorningPickRule.explainedScore

    /// One recorded explanation, staged for the reply it belongs to.
    struct Explanation: Equatable, Sendable {
        let sourceIDs: [String]
        let verdict: Verdict
        /// `explain`, or `connect` when it tied two sources together.
        var operation: MemoryQuestionOperation { sourceIDs.count > 1 ? .connect : .explain }

        /// Reads the tool's arguments against the chat's sources: every id
        /// must be one of them. Nil, with the reason, otherwise.
        static func validate(arguments: [String: Any], chatSourceIDs: Set<String>) -> Result<Explanation, ExplanationError> {
            let ids = ((arguments["source_ids"] as? [Any]) ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !ids.isEmpty else {
                return .failure(ExplanationError(message: "Error: source_ids must name the source or sources the explanation was about."))
            }
            let unknown = ids.filter { !chatSourceIDs.contains($0) }
            guard unknown.isEmpty else {
                return .failure(ExplanationError(message: "Error: \(unknown.joined(separator: ", ")) is not one of this chat's sources. Use ids from the source catalog."))
            }
            guard let raw = arguments["verdict"] as? String, let verdict = Verdict(rawValue: raw) else {
                return .failure(ExplanationError(message: "Error: verdict must be held, partial or missing."))
            }
            var seen = Set<String>()
            return .success(Explanation(sourceIDs: ids.filter { seen.insert($0).inserted }, verdict: verdict))
        }
    }

    struct ExplanationError: Error, Equatable {
        let message: String
    }

    /// The tool as the tutor is offered it.
    static var recordToolSpec: AIToolSpec {
        AIToolSpec(
            name: recordToolName,
            description: "Record, silently, how well the learner's own explanation of a source held, so tomorrow's review knows what they can already explain. Call it only after the learner has tried: once when a gap they had is closed in their own words, and once when their simplest version of the whole holds together. Never before they try, and never say that you are recording anything. verdict: held (they explained it soundly in their own words), partial (the shape is there, a real piece is still missing or wrong), missing (they could not explain it even after help). Pass two or more source_ids only when the explanation tied those sources together.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source_ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "The source or sources the explanation was about, from the source catalog."
                    ] as [String: Any],
                    "verdict": [
                        "type": "string",
                        "enum": Verdict.allCases.map(\.rawValue),
                        "description": "held, partial or missing."
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["source_ids", "verdict"],
            ]
        )
    }

    /// Rides after `Prompts.teachBackTutor` in a chat that offers the tool.
    /// Kept apart because Web sends the tutor's words byte for byte and has
    /// no such tool.
    static let recordingInstruction = """
    After the learner has tried, record how their explanation held with record_explanation: once when a gap they had is closed in their own words, and once when their simplest version of the whole holds together. It is silent; never mention it or show a score.
    """
}

extension TeachBack {
    /// This morning's chat title.
    static func morningTopic(sourceTitles: [String]) -> String {
        "This morning: " + sourceTitles.joined(separator: " and ")
    }

    /// This morning's first message, written ahead: the pick named, why it
    /// came back, and the ask to explain it from memory.
    static func morningOpeningMessage(pick: MorningPick, sourceTitles: [String]) -> String {
        let first = sourceTitles.first ?? "it"
        let ask = "in your own words, from memory, in whatever order it comes. I'll show you pictures from your sources and ask about the gaps."
        switch pick.reason {
        case .yesterday:
            return "Good morning. Yesterday you spent time with “\(first)”. Explain it to me \(ask)"
        case .keptNotExplained:
            return "Good morning. You kept a card for “\(first)”, and it is starting to fade. Before the card comes up, explain the whole of it to me \(ask)"
        case .explainedDry:
            return "Good morning. You explained “\(first)” once; it is drying out. Explain it again, briefly, \(ask)"
        case .connection:
            let second = sourceTitles.dropFirst().first ?? "something you explained before"
            return "Good morning. Yesterday you spent time with “\(first)”, and you have explained “\(second)” before. How do they fit together? Explain it to me \(ask)"
        }
    }

    /// The morning chat's id prefix, inside the teach-back's: the tutor
    /// stays the teach-back's, and the panel knows to offer the morning's
    /// buttons.
    static let morningSessionIDPrefix = sessionIDPrefix + "morning-"

    static func morningSessionID(uuid: UUID = UUID()) -> String {
        morningSessionIDPrefix + uuid.uuidString
    }

    static func isMorningSessionID(_ sessionID: String?) -> Bool {
        sessionID?.hasPrefix(morningSessionIDPrefix) == true
    }
}
