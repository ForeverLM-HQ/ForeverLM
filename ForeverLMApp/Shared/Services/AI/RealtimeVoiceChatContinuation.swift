import Foundation

/// A typed chat carried on out loud: the chat composer's voice button starts
/// voice mode's assistant (`RealtimeVoiceAssistant`) knowing the chat so far,
/// and what ForeverLM said goes back into the same chat as one message when
/// the conversation ends (product owner, 2026-11-08: "it should also be added
/// maybe to a chat where I can continue a chat into voice conversation").
///
/// Nothing transcribes the learner's words (product owner, 2026-11-07), so the
/// chat gets ForeverLM's side as the realtime model gave it with its audio,
/// and a mark where the learner spoke. The chat's model reads that message
/// like any other reply, so typing after the call carries on from it.
enum RealtimeVoiceChatContinuation {
    /// One turn of the typed chat, as the voice model is told it.
    struct ChatTurn: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            case learner
            case assistant
        }

        let role: Role
        let text: String
    }

    /// The chat being continued: where the note goes back, and what it said.
    struct Chat: Equatable, Sendable {
        let sessionID: String
        let title: String
        let turns: [ChatTurn]
    }

    /// The tail of the chat the voice model is told: the latest turns, about
    /// 6k tokens, so a long chat never crowds out the conversation.
    static let transcriptBudget = 24_000

    /// The chat as one section of the assistant's picture, its latest turns
    /// kept whole and the oldest cut once `transcriptBudget` is spent.
    static func section(for chat: Chat) -> RealtimeVoiceAssistant.Section {
        var kept: [String] = []
        var used = 0
        for turn in chat.turns.reversed() {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let line = (turn.role == .learner ? "Learner: " : "ForeverLM: ") + text
            if used + line.count > transcriptBudget {
                if kept.isEmpty {
                    // The newest turn alone is longer than the budget: keep its end.
                    kept.append("… " + String(line.suffix(transcriptBudget)))
                }
                kept.append("… (earlier turns of the chat are left out)")
                break
            }
            kept.append(line)
            used += line.count
        }
        let title = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.isEmpty ? "" : "The chat is titled \u{201C}\(title)\u{201D}.\n\n"
        let body = kept.isEmpty ? "The chat has no messages yet." : kept.reversed().joined(separator: "\n\n")
        return RealtimeVoiceAssistant.Section(title: "This chat so far", text: heading + body)
    }

    /// What the conversation is told before it starts, after the assistant's
    /// own instructions: this is the chat on the screen, carried on by voice.
    static let instructions = """
    This conversation continues the typed chat below, out loud: the learner pressed the voice button in it. \
    Pick up from where it left off, as the same assistant, and keep everything it settled. What you say is \
    added to that chat when the call ends, so a later typed turn can build on it.
    """

    /// The hidden first learner turn that makes the model speak first.
    static func kickoff(hasMessages: Bool) -> String {
        hasMessages
            ? "(The learner just switched this chat to voice. In one short sentence say where the chat left off, then ask what they would like to go into. Then listen.)"
            : "(The learner just started a voice conversation from an empty chat. Greet them in one short sentence and ask what they would like to talk about, offering one specific suggestion from what you know.)"
    }

    /// The message the chat keeps: ForeverLM's words in order, a mark where the
    /// learner spoke, and an interrupted reply marked as cut off. Nil when
    /// ForeverLM said nothing.
    static func note(turns: [RealtimeVoiceTurn], startedAt: Date, endedAt: Date) -> String? {
        var lines: [String] = []
        var learnerSpoke = false
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch turn.role {
            case .learner:
                learnerSpoke = true
            case .tutor:
                guard !text.isEmpty else { continue }
                if learnerSpoke, !lines.isEmpty { lines.append("*You spoke.*") }
                learnerSpoke = false
                lines.append(turn.wasInterrupted ? text + " *(cut off)*" : text)
            }
        }
        guard !lines.isEmpty else { return nil }
        if learnerSpoke { lines.append("*You spoke.*") }
        let minutes = max(1, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
        let header = "**Voice conversation** \u{00B7} \(minutes) min \u{00B7} what ForeverLM said; your words are not transcribed."
        return ([header] + lines).joined(separator: "\n\n")
    }
}
