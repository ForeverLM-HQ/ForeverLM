import Foundation
import OSLog

/// Memory Check by Voice on the iPhone (`RealtimeVoiceMemoryCheck`): today's
/// cards over every notebook, dealt as the card review deals them, then
/// today's memory review — found, or prepared here as the typed review
/// prepares it — asked, graded and saved on the day's review record as the
/// typed review saves it. When the review cannot be had (nothing read yet,
/// not signed in), the cards still run and the learner hears why.
@MainActor
enum MobileRealtimeMemoryCheck {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "RealtimeMemoryCheck")

    /// The instructions OpenAI echoes back over the data channel, which caps
    /// a message near 256 KB (`RealtimeVoiceTutor.inlineTextBudget` is the
    /// same allowance for a source).
    static let instructionBudget = 180_000

    struct NothingToCheck: LocalizedError {
        let reason: String?
        var errorDescription: String? {
            "No cards are due and today's review isn't ready." + (reason.map { " \($0)" } ?? "")
        }
    }

    struct TooLong: LocalizedError {
        var errorDescription: String? {
            "Today's review is too long to run by voice. Open it in Memory on the iPhone or on the Mac."
        }
    }

    static func brief(now: Date = Date()) async throws -> RealtimeVoiceBrief {
        let cards = MobileRealtimeCardTools(scope: .allNotebooks)
        let dealt = await cards.deal(limit: RealtimeVoiceCardReview.cardsInInstructions)

        var review: MobileMemoryReviewRecord?
        var problem: String?
        do {
            review = try await MobileMemoryReviewStore.shared.fetch(sessionID: MemoryReviewSession.sessionID(for: now))
            if review == nil {
                review = try await MobileMemoryReviewPreparer.shared.prepare(now: now)
            }
        } catch {
            logger.error("Memory check without the review: \(error.localizedDescription, privacy: .public)")
            problem = error.localizedDescription
        }

        guard let review, let briefing = review.briefing, !briefing.isEmpty else {
            guard !dealt.cards.isEmpty else { throw NothingToCheck(reason: problem) }
            MobileRealtimeVoice.memoryCheck = nil
            // The cards alone, and why the review is missing.
            let note = "Today's memory review could not be had: \(problem ?? "it has no plan yet"). Say so in one sentence after the cards, then ask whether they are done."
            return RealtimeVoiceBrief(
                title: RealtimeVoiceMemoryCheck.title,
                instructions: RealtimeVoiceCardReview.instructions(
                    cards: dealt.cards,
                    dueToday: dealt.dueToday,
                    scopeTitle: "all their notebooks"
                ) + "\n\n" + note,
                kickoff: RealtimeVoiceCardReview.kickoff(cardCount: dealt.dueToday),
                toolbox: MobileRealtimeCardReview.Toolbox(cards: cards),
                source: nil
            )
        }

        let grading = await MobileMemoryReviewGrading.load(for: review)
        var history = MobileMemoryReviewViewModel.providerHistory(from: review)
        func instructions() -> String {
            RealtimeVoiceMemoryCheck.instructions(
                cards: dealt.cards,
                dueCards: dealt.dueToday,
                review: .init(briefing: briefing, history: history, byTopic: review.isByTopic),
                localClockDescription: MobileMemoryReviewViewModel.localClockDescription()
            )
        }
        var text = instructions()
        // A long morning of typing first: the latest turns are what matter.
        while text.count > instructionBudget, history.count > 6 {
            history.removeFirst(history.count / 2)
            text = instructions()
        }
        guard text.count <= instructionBudget else { throw TooLong() }

        let toolbox = Toolbox(cards: cards, dealtCards: dealt.dueToday, review: review, grading: grading)
        MobileRealtimeVoice.memoryCheck = toolbox
        return RealtimeVoiceBrief(
            title: RealtimeVoiceMemoryCheck.title,
            instructions: text,
            kickoff: RealtimeVoiceMemoryCheck.kickoff(
                cardCount: dealt.dueToday,
                resumingReview: review.exchanges.contains(where: \.isAnswered)
            ),
            toolbox: toolbox,
            source: nil
        )
    }

    /// The conversation's tools: the cards' two, the review's grader, and the
    /// three that stand in for the typed review's screen. The review half's
    /// turns are saved through `RealtimeVoiceMemoryCheckLedger` as they
    /// close, the last when the conversation ends (`finish`).
    final class Toolbox: RealtimeVoiceToolbox, @unchecked Sendable {
        private let cards: MobileRealtimeCardTools
        private let hasCards: Bool
        private let byTopic: Bool
        private let store = MobileMemoryReviewStore.shared

        // Main-actor state; tool calls arrive one at a time per conversation.
        @MainActor private var review: MobileMemoryReviewRecord
        @MainActor private var grading: MobileMemoryReviewGrading
        @MainActor private var ledger: RealtimeVoiceMemoryCheckLedger
        @MainActor private var lastProbeKind: MemoryUnderstandingProbe.Kind?
        @MainActor private var finished = false

        @MainActor
        init(cards: MobileRealtimeCardTools, dealtCards: Int, review: MobileMemoryReviewRecord, grading: MobileMemoryReviewGrading) {
            self.cards = cards
            hasCards = dealtCards > 0
            byTopic = review.isByTopic
            self.review = review
            self.grading = grading
            ledger = RealtimeVoiceMemoryCheckLedger(reviewHadQuestion: !review.exchanges.isEmpty)
        }

        var toolDefinitions: [[String: Any]] {
            var tools: [[String: Any]] = []
            if hasCards {
                tools.append(RealtimeVoiceCardReview.dueCardsTool(
                    description: "More of today's due cards, once the ones in your instructions are done: only cards not dealt yet in this check."
                ))
                tools.append(RealtimeVoiceCardReview.gradeCardTool)
                tools.append(RealtimeVoiceCardReview.deleteCardTool)
                tools.append(RealtimeVoiceCardReview.undoDeleteCardTool)
                tools.append(RealtimeVoiceCardReview.cardSourceTool())
            }
            tools.append(RealtimeVoiceMemoryCheck.startReviewTool)
            tools.append(RealtimeVoiceMemoryCheck.turnTool(byTopic: byTopic))
            tools.append(RealtimeVoiceMemoryCheck.gradeTool(byTopic: byTopic))
            tools.append(RealtimeVoiceMemoryCheck.steerTool)
            tools.append(MemoryReviewTutoring.setReviewDepthTool.requestDictionary)
            return tools
        }

        func run(name: String, argumentsJSON: String) async -> String {
            if let output = await cards.run(name: name, argumentsJSON: argumentsJSON, onlyNew: true) {
                return output
            }
            let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
            return await handle(name: name, arguments: arguments)
        }

        /// The review is filed as the day's review, not as a voice chat.
        func openedSourceIDs() async -> [String] { [] }

        @MainActor
        private var transcriptCount: Int { MobileRealtimeVoice.controller.transcript.count }

        @MainActor
        private func handle(name: String, arguments: [String: Any]) async -> String {
            switch name {
            case RealtimeVoiceMemoryCheck.startReviewToolName:
                ledger.startReview(at: transcriptCount)
                return #"{"ok":true}"#

            case RealtimeVoiceMemoryCheck.turnToolName:
                let id = ((arguments["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let known = byTopic ? review.topics.contains { $0.id == id } : review.sourceIDs.contains(id)
                guard known else {
                    return #"{"error":"That id is not one of today's \#(byTopic ? "topics" : "sources"). Use one exactly as the briefing gives it."}"#
                }
                ledger.turn(to: id, at: transcriptCount)
                return #"{"ok":true}"#

            case RealtimeVoiceMemoryCheck.steerToolName:
                guard let steer = (arguments["steer"] as? String).flatMap(MemoryReviewSteer.init(rawValue:)) else {
                    return #"{"error":"steer is next or deeper."}"#
                }
                let saveNote = await closeTurn()
                ledger.begin(.init(answer: MemoryReviewTutoring.steerMessage(steer), grade: nil, steer: steer))
                var output: [String: Any] = ["ok": true]
                if steer == .deeper, let probe = grading.understandingProbe(review: review, lastProbeKind: lastProbeKind) {
                    lastProbeKind = probe.kind
                    output["note"] = probe.note
                }
                if let saveNote { output["note_on_saving"] = saveNote }
                return Self.json(output)

            case MemoryReviewTutoring.gradeMemoryContourTool.name, MemoryReviewTutoring.gradeTopicRecallTool.name:
                let saveNote = await closeTurn()
                let learnerSaid = (arguments[RealtimeVoiceMemoryCheck.learnerSaidField] as? String) ?? ""
                var gradeArguments = arguments
                gradeArguments.removeValue(forKey: RealtimeVoiceMemoryCheck.learnerSaidField)
                switch grading.validate(arguments: gradeArguments, review: review) {
                case .success(let grade):
                    ledger.begin(.init(
                        answer: RealtimeVoiceMemoryCheck.savedAnswer(learnerSaid: learnerSaid),
                        grade: grade,
                        steer: nil
                    ))
                    let words = grading.acknowledgement(for: grade, review: review)
                        + " Out loud: write no turn line; call \(RealtimeVoiceMemoryCheck.turnToolName) just before the next \(byTopic ? "topic" : "source")'s first question."
                    var output: [String: Any] = ["recorded": true, "next": words]
                    if let saveNote { output["note_on_saving"] = saveNote }
                    return Self.json(output)
                case .failure(let failure):
                    return Self.json(["error": MobileMemoryReviewGrading.rejection(failure, review: review)])
                }

            case MemoryReviewTutoring.setReviewDepthTool.name:
                guard let depth = (arguments["depth"] as? String).flatMap({ MemoryReviewDepth(rawValue: $0.lowercased()) }) else {
                    return #"{"error":"depth is quick, standard or deep."}"#
                }
                grading = await grading.applyingDepth(
                    depth,
                    sourceID: arguments["source_id"] as? String,
                    sourceType: arguments["source_type"] as? String,
                    review: review
                )
                return #"{"ok":true}"#

            default:
                return #"{"error":"Unknown tool."}"#
            }
        }

        /// Saves the turn the ledger was holding. Nil when it saved, or
        /// words for the model when it could not.
        @MainActor
        private func closeTurn() async -> String? {
            let writes = ledger.close(at: transcriptCount, transcript: MobileRealtimeVoice.controller.transcript)
            do {
                try await save(writes)
                return nil
            } catch {
                MobileRealtimeMemoryCheck.logger.error("Memory check turn not saved: \(error.localizedDescription, privacy: .public)")
                return "The last answer could not be saved (\(error.localizedDescription)). Say so in a few words and carry on."
            }
        }

        /// The conversation ended: its last turn, with what was said after it.
        /// `transcript` is the controller's, taken as the call ended.
        @MainActor
        func finish(transcript: [RealtimeVoiceTurn]) async {
            guard !finished else { return }
            finished = true
            do {
                try await save(ledger.finish(transcript: transcript))
            } catch {
                MobileRealtimeMemoryCheck.logger.error("Memory check's last turn not saved: \(error.localizedDescription, privacy: .public)")
            }
        }

        @MainActor
        private func save(_ writes: [RealtimeVoiceMemoryCheckLedger.Write]) async throws {
            for write in writes {
                switch write {
                case .opening(let question):
                    review = try await store.recordOpeningQuestion(sessionID: review.id, question: question)
                case .turn(let answer, let reply, let grade, let steer):
                    review = try await store.recordTurn(
                        sessionID: review.id,
                        answer: answer,
                        reply: reply,
                        grade: grade,
                        steerBefore: steer
                    )
                }
            }
        }

        private static func json(_ object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return #"{"ok":true}"# }
            return text
        }
    }
}
