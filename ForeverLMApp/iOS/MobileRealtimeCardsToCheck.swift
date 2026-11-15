import Foundation
import OSLog
import os

/// Check Cards by Voice on the iPhone and in CarPlay (`RealtimeVoiceCardsToCheck`):
/// the cards waiting in To Check, dealt as To Check deals them and decided by
/// voice. A decision is written as the screen writes Keep, Edit then Keep and
/// Skip (`MobileAudioReviewViewModel.triageCardsToCheck`), so a card kept in
/// the car is a card of Memory at once.
enum MobileRealtimeCardsToCheck {
    struct NothingToCheck: LocalizedError {
        var errorDescription: String? { "No cards are waiting to be checked." }
    }

    @MainActor
    static func brief(scope: MemoryReviewScope, scopeTitle: String) async throws -> RealtimeVoiceBrief {
        let tools = MobileRealtimeToCheckTools(scope: scope)
        let dealt = await tools.deal(limit: RealtimeVoiceCardsToCheck.cardsInInstructions)
        guard !dealt.cards.isEmpty else { throw NothingToCheck() }
        return RealtimeVoiceBrief(
            title: RealtimeVoiceCardsToCheck.title,
            instructions: RealtimeVoiceCardsToCheck.instructions(
                cards: dealt.cards,
                waiting: dealt.waiting,
                scopeTitle: scope == .allNotebooks ? "all their notebooks" : "the notebook \u{201C}\(scopeTitle)\u{201D}"
            ),
            kickoff: RealtimeVoiceCardsToCheck.kickoff(waiting: dealt.waiting),
            toolbox: Toolbox(tools: tools),
            source: nil
        )
    }

    final class Toolbox: RealtimeVoiceToolbox, @unchecked Sendable {
        private let tools: MobileRealtimeToCheckTools

        init(tools: MobileRealtimeToCheckTools) {
            self.tools = tools
        }

        var toolDefinitions: [[String: Any]] {
            [
                RealtimeVoiceCardsToCheck.listTool(
                    description: "More cards waiting to be checked, once the ones in your instructions are done: only cards not dealt yet in this conversation."
                ),
                RealtimeVoiceCardsToCheck.decideTool,
            ]
        }

        func run(name: String, argumentsJSON: String) async -> String {
            await tools.run(name: name, argumentsJSON: argumentsJSON, onlyNew: true)
                ?? #"{"error":"Unknown tool."}"#
        }

        /// The cards span many sources.
        func openedSourceIDs() async -> [String] { [] }
    }
}

/// The cards to check for a voice conversation, and their decisions. Only a
/// card this conversation dealt can be decided, and each once.
final class MobileRealtimeToCheckTools: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeCardsToCheck")

    let scope: MemoryReviewScope
    /// Each dealt card by id, as it is decided.
    private let dealt = OSAllocatedUnfairLock(initialState: [String: MemoryCardToCheck]())
    /// Decided cards, by id: true when kept.
    private let decided = OSAllocatedUnfairLock(initialState: [String: Bool]())

    init(scope: MemoryReviewScope) {
        self.scope = scope
    }

    /// Answers `get_cards_to_check` and `decide_card`; nil for any other tool.
    func run(name: String, argumentsJSON: String, onlyNew: Bool) async -> String? {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case RealtimeVoiceCardsToCheck.listToolName:
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 10, 1), 20)
            let result = await deal(limit: limit, onlyNew: onlyNew)
            return RealtimeVoiceCardsToCheck.listOutput(result.cards, waiting: result.waiting)
        case RealtimeVoiceCardsToCheck.decideToolName:
            return await decide(arguments)
        default:
            return nil
        }
    }

    /// The cards still to check in the scope, in To Check's order; `onlyNew`
    /// leaves out cards this conversation already dealt. `waiting` counts
    /// every card still to check.
    @MainActor
    func deal(limit: Int, onlyNew: Bool = false) async -> (cards: [RealtimeVoiceCardsToCheck.Card], waiting: Int) {
        let vm = MobileAudioReviewViewModel.shared
        guard let pile = await vm.cardsToCheck(scope: scope) else { return ([], 0) }
        let gone = Set(decided.withLock { $0.keys })
        let waiting = pile.filter { !gone.contains($0.cardID) }
        let already = onlyNew ? Set(dealt.withLock { $0.keys }) : []
        let cards = Array(waiting.filter { !already.contains($0.cardID) }.prefix(limit))
        dealt.withLock { held in
            for card in cards { held[card.cardID] = card }
        }
        return (
            cards.map { card in
                let title = vm.sourcesByID[card.sourceID]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return RealtimeVoiceCardsToCheck.Card(
                    id: card.cardID,
                    front: card.face.front,
                    back: card.face.back,
                    why: card.face.why.joined(separator: " "),
                    source: title.isEmpty ? nil : title,
                    sourceID: card.sourceID
                )
            },
            waiting.count
        )
    }

    /// A decision, written as To Check writes it. Keep with the learner's own
    /// words is Edit then Keep; a source's rest is Keep All or Skip All.
    @MainActor
    func decide(_ arguments: [String: Any]) async -> String {
        let cardID = ((arguments["card_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let action = ((arguments["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let card = dealt.withLock({ $0[cardID] }) else {
            return #"{"error":"That card_id is not one dealt in this conversation."}"#
        }
        var decisions: [MemoryCardTriageDecision] = []
        switch action {
        case "keep", "skip":
            if decided.withLock({ $0[cardID] }) != nil {
                return #"{"ok":true,"note":"Already decided in this conversation."}"#
            }
            if action == "skip" {
                decisions = [MemoryCardTriageDecision(card: card, action: .skip)]
            } else {
                decisions = [MemoryCardTriageDecision(card: card, action: Self.keepAction(card, arguments))]
            }
        case "keep_source", "skip_source":
            let vm = MobileAudioReviewViewModel.shared
            let gone = Set(decided.withLock { $0.keys })
            let rest = (await vm.cardsToCheck(scope: scope) ?? []).filter { $0.sourceID == card.sourceID && !gone.contains($0.cardID) }
            decisions = action == "keep_source"
                ? MemoryCardTriage.keepAll(rest)
                : rest.map { MemoryCardTriageDecision(card: $0, action: .skip) }
        default:
            return #"{"error":"action is keep, skip, keep_source or skip_source."}"#
        }
        guard !decisions.isEmpty else { return #"{"ok":true,"note":"Nothing is left to decide there."}"# }
        let result = await MobileAudioReviewViewModel.shared.triageCardsToCheck(decisions)
        let failed = Set(result.failed.map(\.cardID))
        decided.withLock { held in
            for decision in decisions where !failed.contains(decision.card.cardID) {
                if case .skip = decision.action { held[decision.card.cardID] = false } else { held[decision.card.cardID] = true }
            }
        }
        var payload: [String: Any] = [
            "kept": result.kept.count,
            "skipped": result.skipped.count,
            "kept_in_this_conversation": decided.withLock { $0.values.filter { $0 }.count },
            "skipped_in_this_conversation": decided.withLock { $0.values.filter { !$0 }.count },
        ]
        if let failure = result.failed.first {
            Self.logger.error("Voice card decision not written: \(failure.reason, privacy: .public)")
            payload["refused"] = result.failed.count
            payload["reason"] = failure.reason
            payload["note"] = "Say briefly that the card stays to check and why, then carry on."
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"ok":true}"#
    }

    /// Keep as drafted, or in the learner's words when they gave any.
    private static func keepAction(_ card: MemoryCardToCheck, _ arguments: [String: Any]) -> MemoryCardTriageAction {
        func text(_ key: String) -> String? {
            let value = ((arguments[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let front = text("front"), back = text("back"), why = text("why")
        guard front != nil || back != nil || why != nil else { return .keep }
        return .keepEdited(MemoryCardEdit(
            front: front ?? card.face.front,
            back: back ?? card.face.back,
            why: why.map { [$0] } ?? card.face.why,
            frontImages: card.face.frontImages,
            backImages: card.face.backImages
        ))
    }
}
