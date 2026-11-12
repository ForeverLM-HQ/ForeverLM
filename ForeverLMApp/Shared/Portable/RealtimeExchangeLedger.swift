/// The mark a realtime voice conversation leaves in its saved review exchanges.
///
/// Voice mode (speech to speech on OpenAI Realtime) records its conversations
/// as review exchanges. One mark in them needs a name: the question recorded
/// for a learner line that no tutor line preceded. Every transcript renderer
/// (the Mac's chat, the iPhone's notebook chats, MCP transcripts) hides it.
public enum RealtimeExchangeLedger {
    /// The question recorded for a learner line that no tutor line preceded:
    /// the learner spoke first, or spoke again before the tutor finished a
    /// reply. Renderers hide it: it names the absence of a question, and a
    /// chat bubble reading "(open conversation)" in the tutor's voice is a bug.
    public static let openConversationQuestion = "(open conversation)"
}
