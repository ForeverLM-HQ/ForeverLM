/// What remains of the realtime voice conversation's exchange ledger.
///
/// Realtime voice (speech to speech, through OpenAI, Gemini and xAI) recorded
/// its conversations as review exchanges until 2026-10-01, when every model
/// moved to OpenRouter and realtime voice went. Those saved conversations stay
/// readable, and one mark in them still needs a name: the question recorded
/// for a learner line that no tutor line preceded. Every transcript renderer
/// (the Mac's chat, the iPhone's notebook chats, MCP transcripts) hides it.
public enum RealtimeExchangeLedger {
    /// The question recorded for a learner line that no tutor line preceded:
    /// the learner spoke first, or spoke again before the tutor finished a
    /// reply. Renderers hide it: it names the absence of a question, and a
    /// chat bubble reading "(open conversation)" in the tutor's voice is a bug.
    public static let openConversationQuestion = "(open conversation)"
}
