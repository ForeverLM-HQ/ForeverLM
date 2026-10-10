import Foundation

extension MCPDataStore {

    /// `generate_explainer`: write the spoken explainer of a paper or article
    /// and, unless told otherwise, start its audio through the same path
    /// `generate_source_audio` takes — so a voice that costs money is quoted
    /// and confirmed exactly as it is for any other source, and the script is
    /// already saved by the time the estimate comes back. With Explainers
    /// switched on for automatic audio, and the
    /// selected voice one automation may spend on, the standing opt-in is the
    /// consent and the audio starts without the quote
    /// (`MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation`).
    ///
    /// `backend` is the writer and `automaticAudioSelection` the voice the
    /// switch is judged against; tests hand in a canned writer and a selection
    /// built by hand, the app the live model route and the live settings.
    func generateExplainer(
        sourceID: String,
        lengthName: String?,
        generateAudio: Bool,
        confirmCost: Bool,
        approvedSpendUSD: Double? = nil,
        backend: ExplainerModelBackend? = nil,
        automaticAudioSelection: AutomaticAudioSelection? = nil
    ) async throws -> String {
        let trimmedID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("source_id is required.")
        }
        let length: ExplainerLength
        if let lengthName, !lengthName.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = ExplainerLength(rawValue: lengthName.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw MCPError.invalidInput(
                    "length must be one of \(ExplainerLength.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            length = parsed
        } else {
            length = .default
        }

        // Holds no store gate (`MCPToolRegistry.selfGatedToolNames`): the
        // writer reads the source and saves the script through the storage
        // actor, and only starting the audio below reads the cached connection.
        let service = ExplainerGeneratorService(
            storage: notebookFileStorage,
            backend: backend ?? explainerBackend ?? LiveExplainerModelBackend(aiService: AIService()),
            figureIndexer: PaperFigureIndexer(storage: notebookFileStorage, aiService: AIService())
        )
        let result: ExplainerGenerationResult
        do {
            result = try await service.run(request: ExplainerRequest(sourceID: trimmedID, length: length))
        } catch let error as ExplainerGenerationError {
            throw MCPError.invalidInput(error.localizedDescription)
        }

        let explainer = result.explainer
        var payload: [String: Any] = [
            "status": "written",
            "explainer_source_id": explainer.id,
            "title": explainer.title,
            "explains_source_id": trimmedID,
            "length": length.rawValue,
            "word_count": explainer.wordCount ?? 0,
            "replaced_existing": result.replacedExisting,
            "message": result.replacedExisting
                ? "Rewrote the explainer; it is the same source as before, with new text."
                : "Saved the explainer as a new text source beside the original. Open it with its source id, or start a review of it.",
        ]

        if generateAudio {
            // The Explainers switch stands in for confirm_cost: the learner
            // agreed once, in Settings, with the library priced in front of
            // them, and this explainer is exactly what they agreed to.
            let startsAutomatically = MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(
                kind: SourceAudioAutomation.explainerKind,
                selection: automaticAudioSelection ?? .current
            )
            // The audio plan reads the library on the cached connection, and
            // the speech itself runs in the app's queue after this answers.
            let audio = try await withStoreGate(.shared) {
                try await generateSourceAudio(
                    sourceIDs: [explainer.id],
                    bookIDs: [],
                    sourceTypeNames: [],
                    confirmCost: confirmCost || startsAutomatically,
                    allowUnsupportedLanguages: false,
                    approvedSpendUSD: approvedSpendUSD
                )
            }
            if let data = audio.data(using: .utf8),
               var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if startsAutomatically {
                    object["cost_confirmed_by"] = "automatic_explainer_audio"
                    object["note"] = "Automatic audio is on for explainers, so the audio started with the selected voice without asking; get_automatic_audio_settings shows the switch."
                }
                payload["audio"] = object
                if object["status"] as? String == "awaiting_confirmation" {
                    payload["message"] = (payload["message"] as? String ?? "")
                        + " The audio was not started: its voice costs money. Show the learner the estimate under audio, and once they agree call generate_source_audio with source_ids [\"\(explainer.id)\"] and confirm_cost: true."
                }
            }
        }
        return try jsonString(payload)
    }
}
