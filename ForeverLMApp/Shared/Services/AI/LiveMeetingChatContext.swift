import Foundation

/// What a chat reads of a meeting that is being recorded live on this Mac.
///
/// A live meeting is an ordinary meeting session from the moment it starts,
/// so a chat holds it the way it holds any source. Its stored text is only a
/// checkpoint, though, saved every minute or so; the words said since live in
/// the recorder. The Mac's recorder sets `provider`, and a chat whose sources
/// include the live session asks it each turn for the transcript and slides so
/// far, which ride in the turn's volatile tail and never in the cached head.
@MainActor
enum LiveMeetingChatContext {
    /// The block for a chat holding `sourceIDs`, or nil when none of them is a
    /// meeting being recorded (or recorded earlier in this run of the app).
    static var provider: ((_ sourceIDs: Set<String>) -> String?)?

    static func turnContext(forSourceIDs sourceIDs: [String]) -> String {
        guard !sourceIDs.isEmpty, let block = provider?(Set(sourceIDs)), !block.isEmpty else { return "" }
        return "\n\n" + block
    }
}
