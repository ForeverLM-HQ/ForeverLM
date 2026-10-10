import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

/// The decisions the phone's turn-by-turn voice conversation
/// (`MobileVoiceConversationController`) makes without a model: which source
/// to offer when it starts with nothing open, whether the learner said yes,
/// which source a spoken title names, whether they asked for the memory
/// review instead, and what it says to open each kind of conversation.
/// Foundation-only, so the Mac unit-test target compiles it.
///
/// Since 2026-10-01 every model goes through OpenRouter (product owner, 2026-09-27),
/// so the phone talks turn by turn: Apple's dictation hears the learner, the
/// learner's chat model answers through the ordinary chat or review, and the
/// answer is spoken. These rules are the parts of that loop no model decides.
enum MobileVoiceConversationRules {
    /// The source a conversation started with nothing open offers, and why
    /// that one.
    struct SuggestedSource: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case nowPlaying
            case scheduledToday
            case recentlyAttended
        }

        let source: MobileCloudSource
        let reason: Reason
    }

    /// The strongest signal first: the audio the phone was last playing (in a
    /// car that is usually what the driver just listened to), then what is on
    /// today's Schedule and not done, then what was read, heard or discussed
    /// most recently. Only a source whose text is ready can be talked about.
    static func suggestedSource(
        nowPlayingSourceID: String?,
        schedule: [MobileScheduledCatalogItem],
        recentAttention: [MemoryTutorRecentSourceActivity],
        sources: [MobileCloudSource],
        now: Date,
        calendar: Calendar
    ) -> SuggestedSource? {
        let ready = Dictionary(
            sources
                .filter { $0.state == "ready" && !$0.isArchived }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if let nowPlayingSourceID, let source = ready[nowPlayingSourceID] {
            return SuggestedSource(source: source, reason: .nowPlaying)
        }
        let today = schedule
            .filter { !$0.isCompleted && calendar.isDate($0.plannedAt, inSameDayAs: now) }
            .sorted { $0.plannedAt < $1.plannedAt }
        for item in today {
            if let source = ready[item.source.id] {
                return SuggestedSource(source: source, reason: .scheduledToday)
            }
        }
        let recent = recentAttention.sorted { $0.discussedAt > $1.discussedAt }
        for activity in recent {
            if let source = ready[activity.sourceID] {
                return SuggestedSource(source: source, reason: .recentlyAttended)
            }
        }
        return nil
    }

    /// The first thing said when the conversation starts with nothing open:
    /// one concrete offer the learner can take with a word, or the question
    /// of which source to talk about; either way today's memory review is
    /// one request away, since in a car nothing on screen says so.
    static func openingOffer(_ suggestion: SuggestedSource?) -> String {
        guard let suggestion else {
            return "Which source would you like to talk about? Or ask for your memory review."
        }
        let title = spokenTitle(suggestion.source.title)
        let why: String
        switch suggestion.reason {
        case .nowPlaying: why = "the one you were just listening to"
        case .scheduledToday: why = "on today's plan"
        case .recentlyAttended: why = "the one you were in last"
        }
        return "Shall I quiz you on \(title), \(why)? Say yes, name another source, or ask for your memory review."
    }

    /// Whether a reply to the opening offer asks for today's memory review
    /// rather than a source: "my memory review", "review my cards", "what's
    /// due", "today's review". Read by word pairs, so "review me on sleep and
    /// memory" is a source, and checked after the titles, so a source whose
    /// title the reply names is still that source.
    static func asksForMemoryReview(_ utterance: String) -> Bool {
        let words = normalizedWords(utterance)
        for (index, word) in words.enumerated() {
            let previous = index > 0 ? words[index - 1] : nil
            let next = index + 1 < words.count ? words[index + 1] : nil
            switch word {
            case "memory":
                // "memory review", "a memory check", "quiz my memory"
                if let next, ["review", "check", "quiz", "test", "cards"].contains(next) { return true }
                if previous == "my" { return true }
            case "cards", "flashcards":
                // "my cards", "today's cards", "the due cards"
                if let previous, ["my", "today's", "todays", "due"].contains(previous) { return true }
            case "review":
                // "my review", "today's review", "the daily review"
                if let previous, ["my", "today's", "todays", "daily"].contains(previous) { return true }
            case "due":
                // "what's due", "anything due"
                if let previous, ["what's", "whats", "anything", "is", "are"].contains(previous) { return true }
            default:
                break
            }
        }
        return false
    }

    /// Said when today's memory review has nothing to ask.
    static let noReviewReply = "Today's review has nothing to ask yet."

    /// What a conversation on one source says first.
    static func sourceGreeting(title: String) -> String {
        "Ask me anything about \(spokenTitle(title)), or say quiz me."
    }

    /// What a conversation on a notebook's ticked sources says first.
    static func notebookGreeting(notebookTitle: String, sourceCount: Int) -> String {
        let sources = sourceCount == 1 ? "its source" : "its \(sourceCount) sources"
        return "Ask me anything about \(spokenTitle(notebookTitle)) and \(sources), or say quiz me."
    }

    /// What a text chat continued by voice says first.
    static let continuationGreeting = "Go ahead, I'm listening."

    /// The learner's first message when they take the opening offer, saved
    /// in the chat as theirs: the offer was a quiz.
    static let acceptedOfferRequest = "Quiz me on this source, one question at a time."

    /// The learner's first message when Review me starts a spoken review of
    /// a notebook's ticked sources.
    static let reviewRequest = "Quiz me on these sources, one question at a time."

    /// Said when no source in the library matched what the learner named.
    static let unmatchedSourceReply = "I couldn't tell which source you mean. Say its title, or part of it."

    /// Said, and shown, when a turn could not be answered; the error itself is
    /// on screen.
    static let failedTurnReply = "Sorry, that didn't go through. Try saying it again."

    /// Rides each spoken turn sent to the chat model, after the learner's own
    /// words and never shown or saved with them: the reply is going to be
    /// heard, perhaps while driving, not read.
    static let spokenTurnInstruction = "(Spoken conversation: the learner hears your reply read aloud and may be driving. Answer in a few short, plain sentences with no markdown, lists, headings or links, and ask at most one question back.)"

    /// Whether a short reply to the opening offer takes it. Only a reply that
    /// is nothing but an acceptance counts: "yes, but the other paper" names
    /// a source and goes to the source match instead.
    static func isAcceptance(_ utterance: String) -> Bool {
        let words = normalizedWords(utterance)
        guard !words.isEmpty, words.count <= 4 else { return false }
        let accepting: Set<String> = [
            "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "alright",
            "absolutely", "definitely", "go", "ahead", "lets", "let's", "do", "it",
            "sounds", "good", "great", "fine", "that", "one", "quiz", "me",
        ]
        let opening: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "alright", "absolutely", "definitely", "go", "lets", "let's", "sounds", "quiz"]
        guard let first = words.first, opening.contains(first) else { return false }
        return words.allSatisfy(accepting.contains)
    }

    /// The source a spoken reply names by its title: the longest title of two
    /// or more words the reply contains, else the one source whose title
    /// contains the whole reply. Nil when nothing matches or more than one
    /// source fits the reply equally, so a model is asked rather than a guess
    /// taken.
    static func titleMatch(utterance: String, sources: [MobileCloudSource]) -> MobileCloudSource? {
        let spokenWords = normalizedWords(utterance)
        let spoken = spokenWords.joined(separator: " ")
        guard spoken.count >= 4 else { return nil }
        let titled = sources
            .filter { !$0.isArchived }
            .map { source -> (source: MobileCloudSource, words: [String]) in
                (source, normalizedWords(source.title))
            }

        let contained = titled
            .filter { $0.words.count >= 2 && " \(spoken) ".contains(" \($0.words.joined(separator: " ")) ") }
            .sorted { $0.words.count > $1.words.count }
        if let best = contained.first {
            let tied = contained.filter { $0.words.count == best.words.count && $0.source.id != best.source.id }
            return tied.isEmpty ? best.source : nil
        }

        guard spokenWords.count >= 2 else { return nil }
        let containing = titled.filter { " \($0.words.joined(separator: " ")) ".contains(" \(spoken) ") }
        return containing.count == 1 ? containing.first?.source : nil
    }

    /// A title as it is said aloud: in curly quotes, so the synthesizer pauses
    /// around it, and without a trailing full stop.
    private static func spokenTitle(_ title: String) -> String {
        var trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return "\u{201C}\(trimmed)\u{201D}"
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}
