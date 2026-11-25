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
