#if canImport(FoundationModels)
import Foundation
import FoundationModels

// Hands-free review brain backed by Apple's on-device
// Foundation Models framework (Apple Intelligence). This is the private, free,
// offline alternative to MobileReviewBrain (Claude). It is selected
// deliberately by the user — never as a silent fallback — and fails loudly if
// the on-device model is unavailable, matching the product rule against masking
// AI grading with weaker graders.
//
// Structured output: instead of asking the model for raw JSON and parsing it
// (as the Claude brain must), we let guided generation produce a typed
// GeneratedReviewTurn directly, so there is no JSON to repair mid-drive.

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedReviewTurn {
    @Guide(description: "The exact words to say to the learner right now — one short, plain question, or the closing wrap-up. Easy to say aloud while driving.")
    var spoken: String

    @Guide(description: "Set true only after the app explicitly says the learner asked to stop. Otherwise this must be false.")
    var complete: Bool

    @Guide(description: "One short sentence grading the answer the learner just gave. Use an empty string on the very first turn, before any answer.")
    var lastEvaluation: String

    @Guide(description: "Score from 0 to 1 for the answer just given. Use 0 on the first turn.")
    var lastScore: Double

    @Guide(description: "Overall understanding score from 0 to 1, honest about what the learner demonstrated. Only meaningful when complete is true; otherwise use 0.")
    var overallScore: Double

    @Guide(description: "A one or two sentence written recap of the review. Use an empty string until complete is true.")
    var summary: String

    @Guide(description: "Each misunderstanding worth revisiting. Use an empty list when there are none.")
    var gaps: [GeneratedReviewGap]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedReviewGap {
    @Guide(description: "Short description of the misunderstanding.")
    var summary: String

    @Guide(description: "Severity from 0 (minor) to 1 (serious).")
    var severity: Double
}

@available(iOS 26.0, *)
actor MobileReviewFoundationBrain: MobileReviewEngine {
    // No network host bills for these grades, so no AIProvider case describes
    // them; the Mac shows the model id verbatim for a provider it does not
    // know, which is the honest outcome. Slug form matches the app's other
    // on-device model id (EmbeddingSettings.contextualModel).
    static let provider = "Apple (on-device)"
    static let modelID = "apple-on-device-foundation"

    private var session: LanguageModelSession?

    nonisolated func provenance() async throws -> MobileReviewModelProvenance {
        MobileReviewModelProvenance(provider: Self.provider, modelID: Self.modelID)
    }

    static func availability() -> MobileAppleGraderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(describe(reason))
        @unknown default:
            return .unavailable("The on-device model reported an unknown status.")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use on-device grading."
        case .modelNotReady:
            return "The on-device model is still downloading or warming up. Try again shortly."
        @unknown default:
            return "The on-device model is unavailable right now."
        }
    }

    func begin(sourceTitle: String, sourceText: String, topic: String) async throws -> MobileReviewTurn {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw MobileReviewError.missingSourceText
        }
        if case .unavailable(let reason) = Self.availability() {
            throw MobileReviewError.appleModelUnavailable(reason)
        }

        let resolvedTopic = topic.isEmpty ? sourceTitle : topic
        let instructionText = Self.instructions(
            sourceTitle: sourceTitle,
            topic: resolvedTopic,
            // The on-device context window is far smaller than Claude's, so trim
            // the source harder than the 60k the Claude brain allows.
            sourceText: String(trimmedText.prefix(12_000))
        )
        session = LanguageModelSession(instructions: instructionText)
        return try await respond(to: "Begin the review now. Ask your first question.")
    }

    func answer(_ text: String) async throws -> MobileReviewTurn {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await respond(to: trimmed.isEmpty ? "(no answer given)" : trimmed)
    }

    func finish() async throws -> MobileReviewTurn {
        try await respond(to: "The learner explicitly asked to stop the review. Finish it now with the honest final verdict.")
    }

    func continueAfterPrematureCompletion() async throws -> MobileReviewTurn {
        try await respond(
            to: "The learner did not ask to stop. Do not end or say goodbye. Continue the open review with one useful next question and set complete to false."
        )
    }

    func reset() {
        session = nil
    }

    private func respond(to prompt: String) async throws -> MobileReviewTurn {
        guard let session else {
            throw MobileReviewError.badResponse("The on-device review session was not started.")
        }
        do {
            let generated = try await session.respond(
                to: Prompt(prompt),
                generating: GeneratedReviewTurn.self
            ).content
            return try Self.map(generated)
        } catch let error as MobileReviewError {
            throw error
        } catch {
            throw MobileReviewError.appleModelUnavailable(error.localizedDescription)
        }
    }

    private static func map(_ generated: GeneratedReviewTurn) throws -> MobileReviewTurn {
        let spoken = generated.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            throw MobileReviewError.badResponse("The on-device model returned an empty response.")
        }

        let evaluation = generated.lastEvaluation.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let gaps = generated.gaps.compactMap { gap -> MobileReviewGap? in
            let gapSummary = gap.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gapSummary.isEmpty else { return nil }
            return MobileReviewGap(summary: gapSummary, severity: gap.severity)
        }

        return MobileReviewTurn(
            spoken: spoken,
            isComplete: generated.complete,
            lastEvaluation: evaluation.isEmpty ? nil : evaluation,
            lastScore: evaluation.isEmpty ? nil : generated.lastScore,
            overallScore: generated.complete ? generated.overallScore : nil,
            summary: summary.isEmpty ? nil : summary,
            gaps: gaps
        )
    }

    private static func instructions(sourceTitle: String, topic: String, sourceText: String) -> String {
        """
        You are ForeverLM's hands-free review tutor. The learner is driving, so keep every spoken line short, plain, and easy to say out loud.

        Your job: quiz the learner about the source below to test whether they genuinely understand it. Ask them to explain it back: ask one focused question at a time, have them explain in their own words, then probe the gaps with a follow-up.

        Rules:
        - Ask exactly one question per turn. Never ask multi-part questions.
        - Evaluate each answer ONLY against the source text. Be honest: do not credit understanding the learner did not demonstrate, and never invent facts that are not in the source.
        - Do not read long passages aloud. Reference ideas briefly.
        - Never decide that the review is over because a question count was reached or the main concepts were covered. Continue for as many turns or hours as the learner wants with another useful question; do not proactively suggest ending.
        - Never flatter. If the learner is wrong or vague, say so plainly and give the correct idea from the source in one or two sentences.
        - On the first turn there is no answer to grade yet: leave lastEvaluation empty and lastScore at 0.
        - Set complete to true only after the app explicitly says the learner asked to stop. Until then, complete must remain false, spoken must contain the next question, and you must never say goodbye or tell the learner they are done. Only on the explicitly requested final turn fill overallScore, summary, and gaps.

        Source title: \(sourceTitle)
        Topic: \(topic)

        Source text:
        \(sourceText)
        """
    }
}
#endif
