import Foundation

/// The iPhone's and iPad's test of a text-to-speech pick
/// (`AIModelQualification`): one short synthesis through `CloudArticleTTS`,
/// the client the phone's playback uses, read and recorded by the Mac's
/// rules. The verdict is kept on this device, as the Mac keeps its own.
extension CloudArticleTTS {
    /// Whether a failed synthesis says something about the model or its
    /// voice. Only a refusal of what the request names
    /// (`AIModelQualification.isSpeechModelRefusal`) or audio that did not
    /// play (which this client reports with the 2xx status it came with)
    /// counts; the account, the balance, the network, a busy endpoint and the
    /// learner's privacy settings leave the pair untested.
    static func qualificationVerdict(for error: Error) -> String? {
        guard let error = error as? GenerationError,
              case .rejected(_, let statusCode, let reason) = error,
              (200..<300).contains(statusCode)
                || AIModelQualification.isSpeechModelRefusal(statusCode: statusCode) else {
            return nil
        }
        if AIDataPolicy.isTrainingPolicyRefusal(reason) || AIDataPolicy.isDataPolicyRefusal(reason) {
            return nil
        }
        return reason
    }

    /// Whether this device may spend a request on a test right now. Reads
    /// the Keychain; call it off the main actor.
    static var canTestPicks: Bool {
        ManagedAI.isSignedIn
            && !AICreditEntitlement.isOutOfCredits
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// The test itself. The number keeps any cache from answering.
    static func qualificationProbe(model: String, voice: String) async throws {
        try await synthesizeQualificationProbe(
            "This is a short test, number \(Int.random(in: 1000...9999)).",
            modelID: model,
            voiceID: voice
        )
    }

    /// Tests one model in one voice and records the verdict.
    @discardableResult
    static func qualifyPick(model: String, voice: String, force: Bool = false) async -> AIModelQualification.Status {
        let voice = AIModelQualification.resolvedSpeechVoice(model: model, voice: voice)
        return await AIModelQualification.qualify(
            slug: AIModelQualification.speechSlug(model: model, voice: voice),
            role: .speech,
            force: force,
            canTest: canTestPicks,
            verdict: qualificationVerdict(for:),
            probe: { try await qualificationProbe(model: model, voice: voice) }
        )
    }

    /// The test a pick in Settings › Text to Speech runs before it is
    /// applied, as Settings › Voice runs it on the Mac: a refusal keeps the
    /// previous pick, and a free model whose test could not finish is applied
    /// and tested when next used.
    static func testBeforeSelecting(model: String, voice: String) async -> AIModelQualification.SelectionVerdict {
        let voice = AIModelQualification.resolvedSpeechVoice(model: model, voice: voice)
        return await AIModelQualification.speechSelectionVerdict(
            slug: AIModelQualification.speechSlug(model: model, voice: voice),
            isFree: OpenRouterAudioPrices.price(for: model, kind: .speech)?.isFree == true,
            canTest: canTestPicks,
            verdict: qualificationVerdict(for:),
            probe: { try await qualificationProbe(model: model, voice: voice) }
        )
    }

    /// Before a text-to-speech request goes out: starts a test of the pick
    /// when it is due, in the background. This is how a free model applied
    /// while its test could not finish is tested when next used.
    static func testPickWhenDue(model: String, voice: String) {
        let voice = AIModelQualification.resolvedSpeechVoice(model: model, voice: voice)
        guard AIModelQualification.needsTest(
            slug: AIModelQualification.speechSlug(model: model, voice: voice),
            role: .speech
        ) else { return }
        Task.detached(priority: .utility) {
            guard canTestPicks else { return }
            await qualifyPick(model: model, voice: voice)
        }
    }

    /// After playback met a refusal of the model or its audio: tests the
    /// pair again in the background. Nothing when it was tested in the last
    /// few minutes.
    static func recheckAfterRefusal(model: String, voice: String) {
        let voice = AIModelQualification.resolvedSpeechVoice(model: model, voice: voice)
        if let record = AIModelQualification.record(
            slug: AIModelQualification.speechSlug(model: model, voice: voice),
            role: .speech
        ), Date().timeIntervalSince(record.testedAt) < 5 * 60 {
            return
        }
        Task.detached(priority: .utility) {
            guard canTestPicks else { return }
            await qualifyPick(model: model, voice: voice, force: true)
        }
    }
}
