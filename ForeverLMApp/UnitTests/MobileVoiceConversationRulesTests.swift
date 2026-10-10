import Foundation
import Testing
@testable import ForeverLM

/// The model-free decisions of the phone's turn-by-turn voice conversation
/// (`MobileVoiceConversationRules`, compiled into this bundle from iOS/): what
/// it offers when nothing is open, what counts as taking the offer, which
/// source a spoken title names, and what a spoken turn asks of the chat model.
@Suite("Mobile voice conversation rules")
struct MobileVoiceConversationRulesTests {
    private let now = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func source(
        _ id: String,
        title: String? = nil,
        state: String = "ready",
        archived: Bool = false
    ) -> MobileCloudSource {
        var source = MobileCloudSource(
            id: id,
            title: title ?? "Source \(id)",
            subtitle: nil,
            sourceType: "paper",
            dateAdded: now,
            hasAudio: false,
            isArchived: archived
        )
        source.state = state
        return source
    }

    private func placement(_ id: String, source: MobileCloudSource, plannedAt: Date) -> MobileScheduledCatalogItem {
        MobileScheduledCatalogItem(
            id: id,
            source: source,
            plannedAt: plannedAt,
            isCompleted: false,
            completedAt: nil,
            groupTitle: nil,
            goalTitles: [],
            goalIDs: [],
            activityDays: [],
            isAutomatic: false
        )
    }

    @Test("The offer follows the audio last played, then today's plan, then recent attention")
    func offersNowPlayingThenTodayThenRecentAttention() throws {
        let calendar = Calendar(identifier: .gregorian)
        let playing = source("playing")
        let scheduled = source("scheduled")
        let recent = source("recent")
        let queued = source("queued", state: "queued")
        let sources = [playing, scheduled, recent, queued]
        let schedule = [
            placement("placement-queued", source: queued, plannedAt: now.addingTimeInterval(-3_600)),
            placement("placement-scheduled", source: scheduled, plannedAt: now.addingTimeInterval(-1_800)),
        ]
        let attention = [MemoryTutorRecentSourceActivity(sourceID: "recent", discussedAt: now)]

        let nowPlaying = MobileVoiceConversationRules.suggestedSource(
            nowPlayingSourceID: "playing",
            schedule: schedule,
            recentAttention: attention,
            sources: sources,
            now: now,
            calendar: calendar
        )
        #expect(nowPlaying?.source.id == "playing")
        #expect(nowPlaying?.reason == .nowPlaying)

        // A source whose text is still queued cannot be talked about, so
        // today's ready one wins.
        let today = MobileVoiceConversationRules.suggestedSource(
            nowPlayingSourceID: nil,
            schedule: schedule,
            recentAttention: attention,
            sources: sources,
            now: now,
            calendar: calendar
        )
        #expect(today?.source.id == "scheduled")
        #expect(today?.reason == .scheduledToday)

        let latest = MobileVoiceConversationRules.suggestedSource(
            nowPlayingSourceID: "not-in-library",
            schedule: [],
            recentAttention: attention,
            sources: sources,
            now: now,
            calendar: calendar
        )
        #expect(latest?.source.id == "recent")
        #expect(latest?.reason == .recentlyAttended)

        #expect(MobileVoiceConversationRules.suggestedSource(
            nowPlayingSourceID: nil,
            schedule: [],
            recentAttention: [],
            sources: sources,
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test("The opening offer names the source and why, or asks which one, and mentions the memory review")
    func openingOfferNamesTheSource() {
        let offer = MobileVoiceConversationRules.SuggestedSource(
            source: source("p", title: "Mechanisms of Learning."),
            reason: .scheduledToday
        )
        let line = MobileVoiceConversationRules.openingOffer(offer)
        #expect(line.contains("\u{201C}Mechanisms of Learning\u{201D}"))
        #expect(line.contains("today's plan"))
        #expect(line.contains("Say yes"))
        #expect(line.contains("memory review"))
        let open = MobileVoiceConversationRules.openingOffer(nil)
        #expect(open.hasPrefix("Which source would you like to talk about?"))
        #expect(open.contains("memory review"))
    }

    @Test("Asking for the memory review is read by word pairs, not by a word")
    func memoryReviewRequest() {
        for reply in [
            "my memory review", "Let's do a memory check", "quiz my memory", "review my cards",
            "my flashcards please", "What's due?", "anything due today", "today's review",
            "Can we do my review", "the due cards",
        ] {
            #expect(MobileVoiceConversationRules.asksForMemoryReview(reply), "\(reply)")
        }
        for reply in [
            "review me on sleep and memory", "the memory paper", "let's review the hall paper",
            "playing cards and probability", "yes", "", "due process",
        ] {
            #expect(!MobileVoiceConversationRules.asksForMemoryReview(reply), "\(reply)")
        }
    }

    @Test("Only a reply that is nothing but a yes takes the offer")
    func acceptance() {
        for reply in ["Yes", "yes please", "Sure.", "OK", "okay", "let's do it", "Go ahead", "quiz me", "Yeah, sounds good"] {
            #expect(MobileVoiceConversationRules.isAcceptance(reply), "\(reply)")
        }
        for reply in ["No", "no thanks", "yes, but the other paper", "the hall paper", "", "do it later maybe tomorrow please"] {
            #expect(!MobileVoiceConversationRules.isAcceptance(reply), "\(reply)")
        }
    }

    @Test("A spoken title picks its source; an ambiguous or tiny reply picks none")
    func titleMatch() {
        let sources = [
            source("a", title: "Mitochondrial Dynamics in Ageing"),
            source("b", title: "Sleep and Memory Consolidation"),
            source("c", title: "Sleep and Memory"),
            source("d", title: "Introduction"),
            source("e", title: "Archived Dynamics Paper", archived: true),
        ]
        // A whole title inside the reply, the longest one winning.
        #expect(MobileVoiceConversationRules.titleMatch(
            utterance: "Let's talk about sleep and memory consolidation please",
            sources: sources
        )?.id == "b")
        // Part of exactly one title.
        #expect(MobileVoiceConversationRules.titleMatch(
            utterance: "mitochondrial dynamics",
            sources: sources
        )?.id == "a")
        // Part of two titles: a model is asked instead.
        #expect(MobileVoiceConversationRules.titleMatch(utterance: "sleep and", sources: sources) == nil)
        // A one-word title never matches by containment; one word never
        // matches a title part.
        #expect(MobileVoiceConversationRules.titleMatch(
            utterance: "the introduction to the hall paper",
            sources: sources
        ) == nil)
        #expect(MobileVoiceConversationRules.titleMatch(utterance: "ageing", sources: sources) == nil)
        // Archived sources are not offered.
        #expect(MobileVoiceConversationRules.titleMatch(
            utterance: "archived dynamics paper",
            sources: sources
        ) == nil)
        #expect(MobileVoiceConversationRules.titleMatch(utterance: "hi", sources: sources) == nil)
    }

    @Test("A spoken turn asks for a short, plain reply with at most one question")
    func spokenTurnInstruction() {
        let instruction = MobileVoiceConversationRules.spokenTurnInstruction
        #expect(instruction.contains("read aloud"))
        #expect(instruction.contains("no markdown"))
        #expect(instruction.contains("at most one question"))
        #expect(instruction.hasPrefix("(") && instruction.hasSuffix(")"))
    }

    @Test("Greetings say what the conversation reads")
    func greetings() {
        #expect(MobileVoiceConversationRules.sourceGreeting(title: "Mechanisms of Learning")
            == "Ask me anything about \u{201C}Mechanisms of Learning\u{201D}, or say quiz me.")
        #expect(MobileVoiceConversationRules.notebookGreeting(notebookTitle: "Sleep", sourceCount: 1)
            .contains("its source,"))
        #expect(MobileVoiceConversationRules.notebookGreeting(notebookTitle: "Sleep", sourceCount: 4)
            .contains("its 4 sources"))
    }
}
