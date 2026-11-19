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
        /// The cards waiting in To Check, gone through on request.
        private let toCheck: MobileRealtimeToCheckTools

        init(cards: MobileRealtimeCardTools) {
            self.cards = cards
            self.toCheck = MobileRealtimeToCheckTools(scope: cards.scope)
        }

        var toolDefinitions: [[String: Any]] {
            [
                RealtimeVoiceCardReview.dueCardsTool(
                    description: "More of today's due cards, once the ones in your instructions are done: only cards not dealt yet in this review."
                ),
                RealtimeVoiceCardReview.gradeCardTool,
                RealtimeVoiceCardReview.deleteCardTool,
                RealtimeVoiceCardReview.undoDeleteCardTool,
                RealtimeVoiceCardReview.cardSourceTool(),
                RealtimeVoiceCardReview.searchCardsTool(),
                RealtimeVoiceCardReview.cardsByDateTool(),
                RealtimeVoiceCardReview.cardsReviewedTool(),
                RealtimeVoiceCardReview.listTopicsTool(),
                RealtimeVoiceCardsToCheck.listTool(
                    description: "The cards waiting in To Check, when the learner asks to go through them: ask each one's question, then decide_card only on their say."
                ),
                RealtimeVoiceCardsToCheck.decideTool,
            ]
        }

        func run(name: String, argumentsJSON: String) async -> String {
            if let answer = await cards.run(name: name, argumentsJSON: argumentsJSON, onlyNew: true) { return answer }
            return await toCheck.run(name: name, argumentsJSON: argumentsJSON, onlyNew: true)
                ?? #"{"error":"Unknown tool."}"#
        }

        /// A card review is filed with no source: its cards span many.
        func openedSourceIDs() async -> [String] { [] }

        func recordedAnswers() async -> [RealtimeVoiceAnswerRecord] { cards.recordedAnswers() }
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
    /// Cards deleted in this conversation, as they were, in the order deleted:
    /// what "undo" brings back.
    private let deleted = OSAllocatedUnfairLock(initialState: [(item: MemoryItem, prompt: String)]())
    /// What the learner said to each graded card, by item id, for the saved
    /// chat; the first grade of a card is the one kept, as it is the one written.
    private let answers = OSAllocatedUnfairLock(initialState: [String: RealtimeVoiceAnswerRecord]())

    init(scope: MemoryReviewScope) {
        self.scope = scope
    }

    /// The graded cards' answers, in the order they were graded.
    func recordedAnswers() -> [RealtimeVoiceAnswerRecord] {
        answers.withLock { $0.values.sorted { $0.recordedAt < $1.recordedAt } }
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
                remembered: (arguments["remembered"] as? Bool) ?? false,
                learnerSaid: arguments["learner_said"] as? String
            )
        case RealtimeVoiceCardReview.deleteCardToolName:
            return await delete(itemID: (arguments["card_id"] as? String) ?? "")
        case RealtimeVoiceCardReview.cardSourceToolName:
            return await cardSource(itemID: (arguments["card_id"] as? String) ?? "")
        case RealtimeVoiceCardReview.undoDeleteCardToolName:
            return await undoDelete(itemID: arguments["card_id"] as? String)
        case RealtimeVoiceCardReview.cardsByDateToolName, RealtimeVoiceCardReview.reviewedCardsToolName:
            let reviewed = name == RealtimeVoiceCardReview.reviewedCardsToolName
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 10, 1), RealtimeVoiceCardReview.searchResultCap)
            let offset = max((arguments["offset"] as? NSNumber)?.intValue ?? 0, 0)
            let span = min(max((arguments["days"] as? NSNumber)?.intValue ?? 1, 1), 366)
            guard let start = RealtimeVoiceCardReview.startOfDay(
                daysAgo: (arguments["days_ago"] as? NSNumber)?.intValue,
                date: arguments["date"] as? String,
                now: Date()
            ) else {
                return #"{"error":"Give days_ago (1 for yesterday) or date as yyyy-MM-dd."}"#
            }
            let cards = await library()
            let matches = reviewed
                ? RealtimeVoiceCardReview.reviewed(cards, attempts: await MobileAudioReviewViewModel.shared.cardAnswerTimes(), from: start, days: span)
                : RealtimeVoiceCardReview.made(cards, from: start, days: span)
            if matches.isEmpty {
                return reviewed
                    ? #"{"cards":[],"matches":0,"note":"No card was answered on that day. Say so and offer another day."}"#
                    : #"{"cards":[],"matches":0,"note":"No kept card was made on that day. Say so and offer another day."}"#
            }
            dealt.withLock { prompts in
                for entry in matches.dropFirst(offset).prefix(limit) { prompts[entry.card.id] = entry.card.question }
            }
            return RealtimeVoiceCardReview.searchOutput(matches, limit: limit, offset: offset)
        case RealtimeVoiceCardReview.searchCardsToolName:
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 10, 1), RealtimeVoiceCardReview.searchResultCap)
            let query = (arguments["query"] as? String) ?? ""
            let offset = max((arguments["offset"] as? NSNumber)?.intValue ?? 0, 0)
            let matches = RealtimeVoiceCardReview.search(await library(), query: query)
            // A found card can be asked and graded like a dealt one.
            dealt.withLock { prompts in
                for entry in matches.dropFirst(offset).prefix(limit) { prompts[entry.card.id] = entry.card.question }
            }
            return RealtimeVoiceCardReview.searchOutput(matches, limit: limit, offset: offset)
        case RealtimeVoiceCardReview.listTopicsToolName:
            let query = (arguments["query"] as? String) ?? ""
            return RealtimeVoiceCardReview.topicsOutput(RealtimeVoiceCardReview.search(await library(), query: query))
        default:
            return nil
        }
    }

    /// Every kept card on the phone, not only today's slice of them.
    @MainActor
    private func library() async -> [RealtimeVoiceCardReview.LibraryCard] {
        let vm = MobileAudioReviewViewModel.shared
        let now = Date()
        return await vm.keptCardListings().map { listing in
            let title = listing.sourceIDs.lazy.compactMap { vm.sourcesByID[$0]?.title }.first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RealtimeVoiceCardReview.LibraryCard(
                card: RealtimeVoiceCardReview.Card(
                    id: listing.itemID,
                    question: listing.face.front,
                    answer: listing.face.back,
                    source: (title?.isEmpty ?? true) ? nil : title,
                    createdAt: listing.createdAt,
                    sourceKind: RealtimeVoiceCardReview.spokenKind(
                        sourceType: listing.sourceIDs.lazy.compactMap { vm.sourcesByID[$0]?.sourceType }.first
                    ),
                    sourceAuthor: {
                        let names = listing.sourceIDs.compactMap { vm.sourcesByID[$0]?.author?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        return names.isEmpty ? nil : names.joined(separator: "; ")
                    }()
                ),
                dueToday: listing.schedule.dueAt <= now
            )
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
                    source: card.sourceID.flatMap { deal.sourceTitles[$0] },
                    sourceKind: RealtimeVoiceCardReview.spokenKind(
                        sourceType: card.sourceID.flatMap { MobileAudioReviewViewModel.shared.sourcesByID[$0]?.sourceType }
                    )
                )
            },
            deal.cards.count
        )
    }

    /// "Delete this card" by voice: the card is retired as the card's menu
    /// retires it (never asked again, its answers kept). Only a card this
    /// conversation dealt or found can be deleted, and a deleted card can no
    /// longer be graded.
    @MainActor
    func delete(itemID: String) async -> String {
        guard let prompt = dealt.withLock({ $0[itemID] }) else {
            return #"{"error":"That card_id is not one dealt in this conversation."}"#
        }
        do {
            let vm = MobileAudioReviewViewModel.shared
            guard let item = await vm.cardAnswerContext(memoryItemID: itemID)?.item else {
                throw MobileCardReviewError.cardGone
            }
            try await vm.retireCard(itemID: itemID)
            dealt.withLock { _ = $0.removeValue(forKey: itemID) }
            deleted.withLock { $0.append((item, prompt)) }
            return #"{"ok":true,"note":"The card is deleted and will not be asked again. Say so in a few words, say they can say undo to bring it back, and go on to the next card."}"#
        } catch {
            Self.logger.error("Voice card delete not saved: \(error.localizedDescription, privacy: .public)")
            return #"{"error":"The card was not deleted. Say so briefly and carry on."}"#
        }
    }

    /// Where a card comes from: each source it stands on with the passage the
    /// card is anchored on and the text around it, read from the source's text
    /// on the phone. A source whose text has not arrived says so.
    @MainActor
    func cardSource(itemID: String) async -> String {
        guard dealt.withLock({ $0[itemID] }) != nil else {
            return #"{"error":"That card_id is not one dealt or found in this conversation."}"#
        }
        let vm = MobileAudioReviewViewModel.shared
        guard let listing = await vm.keptCardListings().first(where: { $0.itemID == itemID }) else {
            return #"{"error":"That card is no longer on this iPhone."}"#
        }
        var rows: [[String: Any]] = []
        for link in listing.links.prefix(3) {
            guard let source = vm.sourcesByID[link.sourceID] else { continue }
            var row: [String: Any] = ["title": source.title]
            if let kind = RealtimeVoiceCardReview.spokenKind(sourceType: source.sourceType) { row["kind"] = kind }
            if let author = source.author, !author.isEmpty { row["author"] = author }
            if !link.quote.isEmpty { row["passage"] = link.quote }
            do {
                let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: link.sourceID)
                if let around = RealtimeVoiceCardReview.excerpt(in: text, around: link.quote) {
                    row["text_around_passage"] = around
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    row["note"] = "The card names no passage; the source has text but only the title is loaded."
                }
            } catch {
                row["note"] = "This source's text is not on the iPhone yet, so only its title and the passage are known."
            }
            rows.append(row)
        }
        guard !rows.isEmpty else {
            return #"{"sources":[],"note":"This card names no source on this iPhone. Say so."}"#
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["sources": rows], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"sources":[]}"#
    }

    /// "Undo" after a voice delete: the card is kept again as it was (status
    /// kept, its answers never left), and can be asked and graded again.
    @MainActor
    func undoDelete(itemID: String?) async -> String {
        let wanted = (itemID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = deleted.withLock { held -> (item: MemoryItem, prompt: String)? in
            let index = wanted.isEmpty ? held.indices.last : held.firstIndex { $0.item.id == wanted }
            return index.map { held.remove(at: $0) }
        }
        guard let entry else {
            return #"{"error":"No card was deleted in this conversation to bring back."}"#
        }
        do {
            try await MobileAudioReviewViewModel.shared.reviveCard(entry.item)
            dealt.withLock { $0[entry.item.id] = entry.prompt }
            return #"{"ok":true,"card_id":"\#(entry.item.id)","note":"The card is back. Say so in a few words and ask its question again."}"#
        } catch {
            deleted.withLock { $0.append(entry) }
            Self.logger.error("Voice card undo not saved: \(error.localizedDescription, privacy: .public)")
            return #"{"error":"The card was not brought back. Say so briefly and carry on."}"#
        }
    }

    /// A grade, written as the card review writes a Forgot or Remembered
    /// (`MobileSelfGradedAnswer`), with what the learner said kept for the
    /// saved chat.
    @MainActor
    func grade(itemID: String, remembered: Bool, learnerSaid: String?) async -> String {
        guard let prompt = dealt.withLock({ $0[itemID] }) else {
            return #"{"error":"That card_id is not one dealt in this conversation."}"#
        }
        if let record = RealtimeVoiceCardReview.answerRecord(
            question: prompt, learnerSaid: learnerSaid, remembered: remembered, at: Date()
        ) {
            answers.withLock { kept in
                if kept[itemID] == nil { kept[itemID] = record }
            }
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
