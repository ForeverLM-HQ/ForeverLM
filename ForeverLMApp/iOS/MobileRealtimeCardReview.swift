import Foundation
import OSLog
import os

/// Review by Voice on the iPhone (`RealtimeVoiceCardReview`): today's cards in
/// the card review's scope, dealt as the card review deals them, put in the
/// conversation's instructions, and graded by voice.
enum MobileRealtimeCardReview {
    struct NothingDue: LocalizedError {
        var errorDescription: String? { "No cards are due today." }
    }

    @MainActor
    static func brief(scope: MemoryReviewScope, scopeTitle: String) async throws -> RealtimeVoiceBrief {
        let cards = MobileRealtimeCardTools(scope: scope)
        let dealt = await cards.deal(limit: RealtimeVoiceCardReview.cardsInInstructions)
        guard !dealt.cards.isEmpty else { throw NothingDue() }
        return RealtimeVoiceBrief(
            title: RealtimeVoiceCardReview.title,
            instructions: RealtimeVoiceCardReview.instructions(
                cards: dealt.cards,
                dueToday: dealt.dueToday,
                scopeTitle: scope == .allNotebooks ? "all their notebooks" : "the notebook \u{201C}\(scopeTitle)\u{201D}"
            ),
            kickoff: RealtimeVoiceCardReview.kickoff(cardCount: dealt.dueToday),
            toolbox: Toolbox(cards: cards),
            source: nil
        )
    }

    final class Toolbox: RealtimeVoiceToolbox, @unchecked Sendable {
        private let cards: MobileRealtimeCardTools

        init(cards: MobileRealtimeCardTools) {
            self.cards = cards
        }

        var toolDefinitions: [[String: Any]] {
            [
                RealtimeVoiceCardReview.dueCardsTool(
                    description: "More of today's due cards, once the ones in your instructions are done: only cards not dealt yet in this review."
                ),
                RealtimeVoiceCardReview.gradeCardTool,
            ]
        }

        func run(name: String, argumentsJSON: String) async -> String {
            await cards.run(name: name, argumentsJSON: argumentsJSON, onlyNew: true)
                ?? #"{"error":"Unknown tool."}"#
        }

        /// A card review is filed with no source: its cards span many.
        func openedSourceIDs() async -> [String] { [] }
    }
}

/// Today's cards for a voice conversation, and their grades. One sitting per
/// conversation: every grade's attempt id derives from it, so a card is
/// graded once however often the model asks, and only a card this
/// conversation dealt can be graded.
final class MobileRealtimeCardTools: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeCards")

    let scope: MemoryReviewScope
    private let sittingKey = "voice-\(UUID().uuidString.lowercased())"
    /// Each dealt card's prompt by item id, as it is graded.
    private let dealt = OSAllocatedUnfairLock(initialState: [String: String]())

    init(scope: MemoryReviewScope) {
        self.scope = scope
    }

    /// Answers `get_due_cards` and `grade_card`; nil for any other tool.
    func run(name: String, argumentsJSON: String, onlyNew: Bool) async -> String? {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case RealtimeVoiceCardReview.dueCardsToolName:
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 10, 1), 20)
            let result = await deal(limit: limit, onlyNew: onlyNew)
            return RealtimeVoiceCardReview.dueCardsOutput(result.cards, dueToday: result.dueToday)
        case RealtimeVoiceCardReview.gradeCardToolName:
            return await grade(
                itemID: (arguments["card_id"] as? String) ?? "",
                remembered: (arguments["remembered"] as? Bool) ?? false
            )
        default:
            return nil
        }
    }

    /// Today's cards in the scope, as the phone's card review deals them
    /// (`MobileCardReviewSession.Backend.live`); `onlyNew` leaves out cards
    /// this conversation already dealt.
    @MainActor
    func deal(limit: Int, onlyNew: Bool = false) async -> (cards: [RealtimeVoiceCardReview.Card], dueToday: Int) {
        let deal = await MobileCardReviewSession.Backend.live().deal(.today(scope), .today, Date())
        let already = onlyNew ? Set(dealt.withLock { $0.keys }) : []
        let cards = Array(deal.cards.filter { !already.contains($0.itemID) }.prefix(limit))
        dealt.withLock { prompts in
            for card in cards { prompts[card.itemID] = card.prompt }
        }
        return (
            cards.map { card in
                RealtimeVoiceCardReview.Card(
                    id: card.itemID,
                    question: card.prompt,
                    answer: card.back,
                    source: card.sourceID.flatMap { deal.sourceTitles[$0] }
                )
            },
            deal.cards.count
        )
    }

    /// A grade, written as the card review writes a Forgot or Remembered
    /// (`MobileSelfGradedAnswer`).
    @MainActor
    func grade(itemID: String, remembered: Bool) async -> String {
        guard let prompt = dealt.withLock({ $0[itemID] }) else {
            return #"{"error":"That card_id is not one dealt in this conversation."}"#
        }
        let backend = MobileCardReviewSession.Backend.live()
        do {
            guard let context = await backend.answerContext(itemID) else {
                throw MobileCardReviewError.cardGone
            }
            let decision = try MobileSelfGradedAnswer.decide(
                item: context.item,
                history: context.history,
                prompt: prompt,
                remembered: remembered,
                sessionKey: sittingKey,
                practice: false,
                at: backend.now()
            )
            guard case .write(let attempt) = decision else {
                return #"{"ok":true,"note":"Already graded, or not counted today."}"#
            }
            _ = try await backend.write(attempt, MemoryTutorIdentity.immutableCurriculumFingerprint(context.item))
            await backend.noteRecorded(attempt)
            return #"{"ok":true}"#
        } catch {
            Self.logger.error("Voice card grade not saved: \(error.localizedDescription, privacy: .public)")
            return #"{"error":"The grade was not saved. Say so briefly and carry on."}"#
        }
    }
}
