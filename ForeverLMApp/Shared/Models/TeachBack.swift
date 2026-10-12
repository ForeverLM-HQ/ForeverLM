import Foundation

// MARK: - Teach back: the learner explains a paper, the tutor probes
//
// A notebook Studio tile (docs-site/studio.md, "The Studio column"; product
// owner, 2026-10-11: "add feynman technique as one of the things we can do in
// a notebook. basically there I have to explain a paper; and it will prod me
// kind of socratically. forcing active recall is really important").
// Where a review is tutor-led (`Prompts.reviewTutor` opens with a plan and
// asks), here the learner leads: the chat opens by asking them to explain one
// paper from memory, and the tutor plays a curious student who never explains
// first (`Prompts.teachBackTutor`). The learner-facing name is the
// tile's (`NotebookStudioTile.teachBack`); everything else here keeps a
// neutral name.

/// What a teach-back chat is known by. The chat's id carries its tutor
/// (`teach-back-<UUID>`), as a course quiz's (`CourseQuizSitting`) and a day's
/// memory review's (`MemoryReviewSession`) do, so a chat reopened on this Mac
/// or another goes on probing: no column records it, and the id syncs with
/// the chat. Web Studio mints and reads the same prefix
/// (`library-teach-back.js`).
enum TeachBack {
    static let sessionIDPrefix = "teach-back-"

    /// A new teach-back chat's id.
    static func sessionID(uuid: UUID = UUID()) -> String {
        sessionIDPrefix + uuid.uuidString
    }

    /// Whether a chat is a teach-back, read from its id.
    static func isSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(sessionIDPrefix)
    }

    /// The chat's title: the tile's name and the paper's.
    static func topic(sourceTitle: String) -> String {
        "Feynman Technique: \(sourceTitle)"
    }

    /// The chat's first message, written ahead so no model is asked before
    /// the learner speaks: the paper named, and the ask to explain it from
    /// memory. Web Studio writes the same words (`teachBackOpening`).
    static func openingMessage(sourceTitle: String) -> String {
        "Explain “\(sourceTitle)” to me in your own words, as you would to a bright friend who hasn't read it. Don't look back at it first: what question does it ask, what did it find, and how does it know? Start wherever you like, and I'll ask about whatever I can't follow yet."
    }
}

/// The Studio's Feynman Technique asked for a chat on one of the notebook's
/// ticked papers, consumed by the Chat panel's auto-start
/// (`StudioViewModel.requestNotebookTeachBack`).
struct TeachBackChatRequest: Equatable, Sendable {
    let notebookID: String
    let sourceID: String
    /// The paper's title as the library shows it.
    let sourceTitle: String
}
