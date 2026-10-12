import Foundation

/// Which sources the phone narrates from the Mac's synced text-to-speech
/// preparation, and which from their own text.
///
/// Papers and articles are narrated from the prepared narration only — the
/// phone never runs the preparation pass — so one that has not synced yet is
/// an error, not a fallback. The one article read as it stands is an
/// explainer's script (explainer-design.md): it was written for the ear, and
/// the pass is never run on it on any device, so the phone reads its text and
/// can generate its audio whether or not a Mac ever has.
enum MobileTextToSpeechNarrationPolicy {
    static func requiresMacPreparedNarration(sourceType: String, url: String?) -> Bool {
        if TextToSpeechPreparationPolicy.isSpokenScript(url: url ?? "") { return false }
        return TextToSpeechPreparationPolicy.alwaysPreparedSourceTypes.contains(sourceType)
    }

    /// Whether a Mac-prepared narration is worth looking for: the types always
    /// prepared. A spoken script never has one.
    static func mayHaveMacPreparedNarration(sourceType: String, url: String?) -> Bool {
        if TextToSpeechPreparationPolicy.isSpokenScript(url: url ?? "") { return false }
        return TextToSpeechPreparationPolicy.alwaysPreparedSourceTypes.contains(sourceType)
    }
}

enum MobileExplainerError: LocalizedError {
    case unsupportedSource(String)
    case noText(String)
    case notSignedIn
    case badResponse(String)
    case emptyScript

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let title):
            return "An explainer can be written about a paper or an article, not about \"\(title)\"."
        case .noText(let title):
            return "\"\(title)\" has no text to explain yet."
        case .notSignedIn:
            return "Sign in to ForeverLM to write an explainer."
        case .badResponse(let message):
            return message
        case .emptyScript:
            return "The writer returned no script."
        }
    }
}

/// The phone's Explain action, shared by the source row's badge and menu and
/// the reader's toolbar: write the explainer with the account's Explainer
/// Writing model, save it as the same article-typed source the Mac writes,
/// then hand it to Listen — which generates its audio when none exists and
/// plays it, exactly as it does for any other source.
///
/// The write is the generator's own task, so Cancel can end it from any
/// surface while the request is still out to the model; the pipeline checks
/// for cancellation before it saves, so a stopped write leaves nothing behind.
@MainActor
final class MobileExplainerGenerator: ObservableObject {
    static let shared = MobileExplainerGenerator()

    /// The sources whose explainer is being written right now, by their id.
    @Published private(set) var writingSourceIDs: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]

    func isWriting(_ sourceID: String) -> Bool {
        tasks[sourceID] != nil
    }

    /// Writes the source's explainer and starts listening to it. A source
    /// already being written is left alone. Returns when the write has ended,
    /// however it ended.
    func explain(_ source: MobileCloudSource, audio: MobileAudioReviewViewModel) async {
        guard tasks[source.id] == nil else { return }
        let task = Task { await self.write(source, audio: audio) }
        tasks[source.id] = task
        writingSourceIDs.insert(source.id)
        await task.value
    }

    /// Stops writing the source's explainer. Nothing is saved; the source
    /// keeps whatever explainer it already had.
    func cancel(_ sourceID: String) {
        tasks[sourceID]?.cancel()
    }

    private func write(_ source: MobileCloudSource, audio: MobileAudioReviewViewModel) async {
        defer {
            tasks[source.id] = nil
            writingSourceIDs.remove(source.id)
        }
        let explainerID: String
        do {
            explainerID = try await Self.writeExplainer(of: source)
        } catch {
            // A cancelled request can surface as its own CancellationError or
            // as the transport's cancelled error; either way the learner asked
            // for it, so it is not a failure.
            if error is CancellationError || Task.isCancelled { return }
            audio.errorMessage = error.localizedDescription
            return
        }
        // The catalog is republished so the row and the reader see the new
        // source before its audio starts; Listen then generates and plays it
        // through the one path every source takes.
        await audio.load()
        await audio.toggleTextToSpeech(sourceID: explainerID)
    }

    /// The pipeline, off the main actor: the source's text, one Explainer
    /// Writing call, the saved source. Returns the explainer's id.
    nonisolated static func writeExplainer(
        of source: MobileCloudSource,
        length: ExplainerLength = .default
    ) async throws -> String {
        guard ExplainerScript.isExplainable(sourceType: source.sourceType, url: source.url) else {
            throw MobileExplainerError.unsupportedSource(source.title)
        }
        let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MobileExplainerError.noText(source.title) }
        // Keychain reads happen here, off the main actor, as everywhere else.
        guard ManagedAI.isSignedIn else { throw MobileExplainerError.notSignedIn }

        // One activity id for the run, so the account's AI activity shows the
        // explainer as one line — the same shape as the Mac's pipeline.
        let workflowID = UUID().uuidString
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.withSource(
                AIUsageSource(id: source.id, type: source.sourceType, title: source.title),
                activityID: workflowID
            ) {
                let draft = try await writeDraft(source: source, text: text, length: length)
                // A cancelled run that the provider still answered must not land
                // a source the learner has already given up on.
                try Task.checkCancellation()
                let explainerID = try await MobileCloudMutationService.shared.saveExplainer(
                    explaining: source,
                    script: draft.script
                )
                await MobileCloudSourceTextStore.shared.storeSourceText(
                    draft.script.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceID: explainerID
                )
                return explainerID
            }
        }
    }

    private nonisolated static func writeDraft(
        source: MobileCloudSource,
        text: String,
        length: ExplainerLength
    ) async throws -> ExplainerDraft {
        let route = try await MobileModelPreferenceStore.shared.resolve(.explainerWriting)
        let budgeted = ExplainerScript.budgeted(text)
        var request = try MobileOpenRouterChat.request(
            route: route,
            system: Prompts.explainerWriter,
            messages: [(role: "user", content: ExplainerScript.writerUserMessage(
                title: source.title,
                sourceType: source.sourceType,
                author: source.author,
                journal: source.journal,
                publishedYear: source.publishedYear,
                text: budgeted.text,
                truncated: budgeted.truncated,
                length: length
            ))],
            maxTokens: 6_000,
            jsonMode: true
        )
        // A whole paper in, a couple of thousand words out: longer than a chat turn.
        request.timeoutInterval = 180
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileExplainerError.badResponse("\(route.provider) did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body."
            // OpenRouter's data-policy refusal answers a switch the learner set
            // in Settings; say so, as the Mac does. The account-level training
            // refusal is translated whatever the switch says. See `AIDataPolicy`.
            if AIDataPolicy.isTrainingPolicyRefusal(body) {
                throw MobileExplainerError.badResponse(
                    AIDataPolicy.trainingRefusalExplanation(providerMessage: AIProviderErrorText.fromResponseBody(data))
                )
            }
            if route.deniesDataCollection, AIDataPolicy.isDataPolicyRefusal(body) {
                throw MobileExplainerError.badResponse(
                    AIDataPolicy.refusalExplanation(providerMessage: AIProviderErrorText.fromResponseBody(data))
                )
            }
            throw MobileExplainerError.badResponse("Explainer writing failed (\(http.statusCode)): \(body)")
        }
        let parsed = try MobileOpenRouterChat.text(from: data)
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)
        let draft: ExplainerDraft
        do {
            draft = try MemoryReviewPlanning.decodeJSON(parsed.text)
        } catch {
            throw MobileExplainerError.badResponse("The writer's reply was not the script it was asked for.")
        }
        guard draft.isUsable else { throw MobileExplainerError.emptyScript }
        return draft
    }
}
