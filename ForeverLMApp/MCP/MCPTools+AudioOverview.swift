#if os(macOS)
import Foundation

// MARK: - generate_audio_overview
//
// A Notebook's audio overview, for an assistant: the Studio tile's options
// and Make in one call (docs/explainer-design.md, "Audio overviews"). The
// call plans and prices first and spends nothing until the learner's voice
// is free, automatic audio covers it, or the assistant passes confirm_cost
// after the learner agreed; then the writing runs as background work with a
// work_id — the same run the app's own Make starts, so it shows as a pending
// row in the Notebook and its Stop ends it — and the audio follows through
// the text-to-speech queue `generate_source_audio` uses.

extension MCPToolRegistry {
    static var audioOverviewToolDef: MCPToolDef {
        MCPToolDef(
            name: "generate_audio_overview",
            description: "Make a Notebook's audio overview in ForeverLM, as its Studio does: one spoken script written over the Notebook's sources by the learner's Audio Overview Writing model and, by default, narrated by their text-to-speech voice. Formats: deep_dive (a thorough tour of what the sources say together, where they agree and conflict, and what stays open; shorter about 7, default about 12, longer about 19 minutes), brief (the core ideas in about 2 minutes; length does not apply) and critique (a constructive expert review of the sources' strengths, weaknesses, methods and gaps; about 5, 8 or 13 minutes). focus leads the script. The sources are the Notebook's own ticked sources (list_notebook_sources in_chat, without a context notebook's rows, via_context_notebook_id; set_notebook_source_selection) unless source_ids names some of its own sources; sources with no text yet are left out and listed. Every source is read whole when the model's context window takes them together; otherwise the longest are read from the ideas stored for them, or from a condensed account of their whole text written for this overview, and the answer says which — nothing is cut. The overview is saved as an Artifact in the Notebook (list_docs kind audio_overview) with its spoken script as a source (audio_source_id), which plays on every device. The first call prices the writing and the audio and starts nothing when the voice costs money: show the learner the estimate, and once they agree call again with confirm_cost true. With automatic audio switched on for explainers (get_automatic_audio_settings, kind explainer), that standing opt-in covers the audio and the overview starts at once. Once started it answers with work_id, overview_id and audio_source_id while the writing runs in the background; list_running_ai_work shows its stage, cancel_ai_work stops it and nothing is saved, get_source_audio_status with the audio_source_id follows the writing and then the audio, cancel_source_audio_generation stops the audio, read_doc returns the recipe and get_source_content the script. Bills the learner's OpenRouter key for the writing and the narration. A team's Notebook cannot hold one yet.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "notebook_id": [
                        "type": "string",
                        "description": "The Notebook the overview is written from and filed in (list_notebooks).",
                    ],
                    "source_ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Write from these of the Notebook's own sources, in this order. Omit for its own ticked sources (in_chat, not via_context_notebook_id).",
                    ],
                    "format": [
                        "type": "string",
                        "enum": AudioOverviewFormat.allCases.map(\.rawValue),
                        "description": "deep_dive (the default), brief or critique.",
                    ],
                    "length": [
                        "type": "string",
                        "enum": AudioOverviewLength.allCases.map(\.rawValue),
                        "description": "shorter, default or longer. Ignored for brief.",
                    ],
                    "focus": [
                        "type": "string",
                        "description": "Optional: what the overview should be about, in the learner's words. It leads the script.",
                    ],
                    "generate_audio": [
                        "type": "boolean",
                        "description": "Narrate the script once it is written. Defaults to true.",
                    ],
                    "confirm_cost": [
                        "type": "boolean",
                        "description": "Pass true only after the learner has seen this tool's estimate and explicitly agreed to the spend. Defaults to false, which prices a paid voice and starts nothing, unless automatic audio is switched on for explainers.",
                    ],
                ],
                "required": ["notebook_id"],
            ]
        )
    }
}

extension MCPDataStore {
    /// `delete_source`. An audio overview's script source goes the way the
    /// overview's own Delete takes it (`AudioOverviewCleanup.deleteCarrier`):
    /// its narration stopped, its generation cancelled, its record deleted
    /// with it and its audio files removed. Every other source is deleted
    /// as before.
    func deleteSourceWithItsAudio(
        _ sourceID: String,
        removeAudioFiles: @escaping @Sendable (String) async -> Void = { await AudioOverviewCleanup.removeAudioFiles(ofCarrier: $0) }
    ) async throws -> String {
        guard let article = try knowledgeStore().loadSourceForSync(sourceID),
              GeneratedAudioOverview.isCarrier(article) else {
            return try deleteSource(sourceID)
        }
        try await AudioOverviewCleanup.deleteCarrier(sourceID, storage: notebookFileStorage, removeAudioFiles: removeAudioFiles)
        return "Deleted the audio overview '\(article.title)' (its script source, id: \(sourceID)) with its record and audio, on every device."
    }

    /// `generate_audio_overview`. `backend` is the writer, `route` the model
    /// route it is sized and priced against, `audioQuote` the narration's
    /// price and `automaticAudioSelection` the voice the automatic switch is
    /// judged against; tests hand in their own, the app the live ones.
    func generateAudioOverview(
        arguments: [String: Any],
        backend: (any AudioOverviewModelBackend)? = nil,
        route: AudioOverviewRoute? = nil,
        audioQuote: (@Sendable (AudioOverviewPlan) async -> AudioOverviewQuote)? = nil,
        automaticAudioSelection: AutomaticAudioSelection? = nil
    ) async throws -> String {
        let notebookID = (arguments["notebook_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !notebookID.isEmpty else {
            throw MCPError.invalidInput("notebook_id is required: the Notebook the audio overview is written from and filed in. list_notebooks shows each id.")
        }
        let options = try Self.audioOverviewOptions(arguments)
        let sourceIDs = (arguments["source_ids"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let generateAudio = arguments["generate_audio"] as? Bool ?? true
        let confirmCost = arguments["confirm_cost"] as? Bool ?? false
        let approvedSpendUSD = (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
            ?? MCPRunningWork.defaultSpendLimitUSD

        // Holds no store gate (`MCPToolRegistry.selfGatedToolNames`): the
        // Notebook and its sources are read through the storage actor, and the
        // writing saves there too.
        let storage = notebookFileStorage
        guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw MCPError.notFound("Notebook not found: \(notebookID). Call list_notebooks for the current ids.")
        }
        guard notebook.teamID == nil else {
            throw MCPError.invalidInput("‘\(notebook.title)’ is a team's Notebook. Audio overviews are made in the learner's own Notebooks for now.")
        }
        let request = AudioOverviewRequest(
            notebookID: notebookID,
            options: options,
            sourceIDs: sourceIDs?.isEmpty == false ? sourceIDs : nil
        )
        let writer = backend ?? LiveAudioOverviewModelBackend(aiService: AIService())
        let plan: AudioOverviewPlan
        do {
            let notebook = try await AudioOverviewGeneratorService(storage: storage, backend: writer)
                .load(notebookID: notebookID, sourceIDs: request.sourceIDs)
            guard let route = route ?? LiveAudioOverviewModelBackend.currentRoute() else {
                throw AudioOverviewGenerationError.noModelConfigured
            }
            plan = try AudioOverviewGeneratorService.plan(notebook, request: request, route: route)
        } catch let error as AudioOverviewGenerationError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let quote: AudioOverviewQuote
        if let audioQuote {
            quote = await audioQuote(plan)
        } else {
            quote = await AudioOverviewQuote.current(for: plan)
        }

        if generateAudio, let error = quote.speechConfigurationError {
            throw MCPError.invalidInput(
                "Nothing was written. The learner's text-to-speech voice cannot narrate right now: \(error) Ask them to choose a voice in ForeverLM Settings › Voice, or call again with generate_audio false to write the script only."
            )
        }
        let narrates = generateAudio
        // The Explainers switch stands in for confirm_cost, as it does for
        // generate_explainer: the learner agreed once, in Settings, to have
        // ForeverLM's spoken scripts narrated with this voice.
        let startsAutomatically = narrates && MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(
            kind: SourceAudioAutomation.explainerKind,
            selection: automaticAudioSelection ?? .current
        )
        var payload = Self.audioOverviewPlanPayload(plan, quote: quote, narrates: narrates)
        payload["notebook"] = notebook.title

        // Only the narration asks first. The writing is bounded by
        // approved_spend_usd below and starts with a free voice, with no audio
        // asked for, or under the Explainers switch, as plan §3.7 decided.
        if narrates, !quote.audioIsFree, !confirmCost, !startsAutomatically {
            payload["status"] = "awaiting_confirmation"
            payload["message"] = "Nothing was written or narrated. This overview would cost \(quote.plan.writingCost.label) to write and \(quote.audioLabel) to narrate with \(quote.voiceLabel). Show the learner the estimate, and only after they explicitly agree call generate_audio_overview again with the same arguments and confirm_cost: true."
            return try jsonString(payload)
        }
        let expected = narrates ? quote.expectedTotalUSD : plan.writingCost.expectedUSD
        if let expected, expected > approvedSpendUSD {
            payload["status"] = "approval_too_low"
            payload["message"] = String(
                format: "Nothing was started. The estimate is $%.2f, above the $%.2f approved ceiling for this operation. Show the learner the estimate and ask before calling again with a larger approved_spend_usd.",
                expected,
                approvedSpendUSD
            )
            return try jsonString(payload)
        }

        let artifactID = UUID().uuidString.lowercased()
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        // The narration's agreed price: the quote, never more. Nil only for a
        // voice this Mac cannot price, which awaited confirm_cost above and
        // is then held to the operation's ceiling.
        let audioCeilingUSD = quote.audio.usd ?? approvedSpendUSD
        let title = notebook.title
        // The open window shows the saved overview when this store is the
        // app's library; a store over another database (a test's) has no window.
        let showsInWindow = dbPathOverride == nil
        let workID = MCPRunningWork.shared.startBackground(
            tool: "generate_audio_overview",
            about: "audio overview of \(title)",
            spendLimitUSD: approvedSpendUSD
        ) { @MainActor [self] in
            let callID = MCPRunningWork.currentCallID
            let coordinator = AudioOverviewGenerationCoordinator.shared
            let result = await coordinator.write(plan, artifactID: artifactID, storage: storage, backend: writer) { stage in
                if let callID { MCPRunningWork.shared.setDetail(callID, stage.label) }
            }
            // A run that ended without a script leaves its note with the
            // coordinator, which get_source_audio_status reads.
            guard case .success(let overview) = result else { return }
            if showsInWindow, let studio = try? AppModelBridge.requireStudio() {
                await coordinator.show(overview, in: studio)
            }
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
            guard narrates, !Task.isCancelled else { return }
            if let callID { MCPRunningWork.shared.setDetail(callID, "Starting its audio") }
            // The quote was agreed (or is free, or automatic audio covers it):
            // the audio is queued as generate_source_audio queues it, on the
            // learner's voice, and get_source_audio_status follows it. The
            // agreement was to the quoted narration price, so that is the
            // ceiling: a script that came out longer is not narrated at a
            // price nobody saw, and the status says so.
            do {
                let answer = try await self.withStoreGate(.shared) {
                    try await self.generateSourceAudio(
                        sourceIDs: [overview.carrier.id],
                        bookIDs: [],
                        sourceTypeNames: [],
                        confirmCost: true,
                        allowUnsupportedLanguages: false,
                        approvedSpendUSD: audioCeilingUSD
                    )
                }
                if let message = Self.audioOverviewAudioRefusal(answer) {
                    coordinator.noteAudioNotStarted(overviewID: artifactID, message: message)
                }
            } catch {
                coordinator.noteAudioNotStarted(overviewID: artifactID, message: error.localizedDescription)
            }
        }
        payload["status"] = "started"
        payload["work_id"] = workID
        payload["overview_id"] = artifactID
        payload["audio_source_id"] = carrierID
        if startsAutomatically {
            payload["cost_confirmed_by"] = "automatic_explainer_audio"
        }
        payload["message"] = "Writing the audio overview of ‘\(title)’ in the background (work_id \(workID)); it takes a minute or more. list_running_ai_work shows its stage and cancel_ai_work stops it. "
            + (narrates
                ? "Its audio starts when the script is saved: get_source_audio_status with source_ids [\"\(carrierID)\"] follows the writing and then the audio."
                : "No audio was asked for; get_source_audio_status with source_ids [\"\(carrierID)\"] says when the script is saved, and generate_source_audio narrates it later.")
            + " read_doc with doc_id \(artifactID) returns its recipe once saved."
        return try jsonString(payload)
    }

    /// Why `generate_source_audio` did not start an overview's audio, from
    /// its answer: the script came out dearer than the agreed estimate
    /// (`approval_too_low`), or anything else but started; nil when it
    /// started or the audio was already there.
    static func audioOverviewAudioRefusal(_ answer: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
              let status = object["status"] as? String else {
            return "The audio did not start: the text-to-speech queue gave no answer."
        }
        switch status {
        case "started", "nothing_to_generate":
            return nil
        case "approval_too_low":
            let message = object["message"] as? String ?? ""
            return "The script came out longer than the estimate the learner agreed to, so its audio was not started. \(message) Call generate_source_audio with the audio_source_id to narrate it at the new price once they agree."
        default:
            return (object["message"] as? String) ?? "The audio did not start (\(status))."
        }
    }

    /// The format, length and focus, from the tool's words.
    static func audioOverviewOptions(_ arguments: [String: Any]) throws -> AudioOverviewOptions {
        var options = AudioOverviewOptions()
        if let raw = (arguments["format"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            guard let format = AudioOverviewFormat(rawValue: raw) else {
                throw MCPError.invalidInput("format must be one of \(AudioOverviewFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            options.format = format
        }
        if let raw = (arguments["length"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            guard let length = AudioOverviewLength(rawValue: raw) else {
                throw MCPError.invalidInput("length must be one of \(AudioOverviewLength.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            options.length = length
        }
        options.focus = (arguments["focus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return options
    }

    /// What the call would make and what it would cost.
    static func audioOverviewPlanPayload(
        _ plan: AudioOverviewPlan,
        quote: AudioOverviewQuote,
        narrates: Bool
    ) -> [String: Any] {
        let options = plan.options
        var writing: [String: Any] = [
            "model": plan.route.model,
            "requests": plan.writingCost.requestCount,
            "estimated_cost": plan.writingCost.label,
            "basis": "The script at its target length and every condensing call; at most is every request's output ceiling, reasoning included.",
        ]
        if let usd = plan.writingCost.expectedUSD { writing["estimated_cost_usd"] = usd }
        if let usd = plan.writingCost.maximumUSD { writing["maximum_cost_usd"] = usd }
        var estimate: [String: Any] = ["writing": writing]
        if narrates {
            var audio: [String: Any] = [
                "provider": quote.speechProvider,
                "model": quote.speechModel,
                "voice": quote.voice,
                "characters": quote.audio.characters,
                "estimated_listening_time": quote.audio.durationLabel,
                "estimated_cost": quote.audio.costLabel,
                "basis": "A script at the most words this format and length ask for.",
            ]
            if let usd = quote.audio.usd { audio["estimated_cost_usd"] = usd }
            if let notice = quote.speechSelectionNotice { audio["selection_repaired"] = notice }
            estimate["audio"] = audio
            if let total = quote.expectedTotalUSD { estimate["total_estimated_cost_usd"] = total }
        }
        var payload: [String: Any] = [
            "notebook_id": plan.request.notebookID,
            "format": options.format.rawValue,
            "length": options.effectiveLength.map { $0.rawValue as Any } ?? NSNull(),
            "focus": options.trimmedFocus.map { $0 as Any } ?? NSNull(),
            "target_words": "\(options.wordRange.lowerBound)-\(options.wordRange.upperBound)",
            "minutes": options.minutes,
            "sources": plan.sources.map { source -> [String: Any] in
                var entry: [String: Any] = [
                    "source_id": source.candidate.source.id,
                    "title": source.candidate.source.title,
                    "read_as": source.readAs.rawValue,
                ]
                if !source.parts.isEmpty { entry["condensing_calls"] = source.parts.count }
                return entry
            },
            "source_count": plan.sources.count,
            "summary": plan.sourcesSummary,
            "estimate": estimate,
        ]
        if !plan.skipped.isEmpty {
            payload["left_out"] = plan.skipped.map {
                ["source_id": $0.sourceID, "title": $0.title, "reason": $0.reason] as [String: Any]
            }
        }
        if plan.sources.contains(where: { $0.readAs != .whole }) {
            payload["reading_note"] = "The writing model's context window cannot take every source whole: read_as ideas means only the ideas stored for that source are given, condensed means a condensed account of its whole text, written for this overview. Nothing is cut."
        }
        return payload
    }

    /// An overview's recipe, as read_doc returns it.
    static func audioOverviewSettingsPayload(_ settings: AudioOverviewSettings) -> [String: Any] {
        [
            "format": settings.format.rawValue,
            "length": settings.length.map { $0.rawValue as Any } ?? NSNull(),
            "focus": settings.focus.map { $0 as Any } ?? NSNull(),
            "hosts": settings.hosts,
            "audio_source_id": settings.audioSourceID,
            "model": settings.model.map { $0 as Any } ?? NSNull(),
            "made_at": KnowledgeStore.iso8601Formatter.string(from: settings.madeAt),
            "summary": settings.recipe,
            "sources": settings.sources.map {
                ["source_id": $0.sourceID, "title": $0.title, "read_as": $0.readAs.rawValue] as [String: Any]
            },
        ]
    }
}
#endif
