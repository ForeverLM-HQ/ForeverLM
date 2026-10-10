#if os(macOS)
import Foundation

/// `generate_explainer_video`: the Videos composer's Make Video, reachable
/// from a chat — above all the chat that plans a generated course, which
/// gives a module a film (docs/course-generation-design.md, "Planning in
/// chat"). The run is `ExplainerVideoGenerationCoordinator`'s, so the price
/// dialog, the progress row in Videos and Cancel are the ones the composer
/// uses; this tool only names the concept and, for a course, the module the
/// finished film is filed under.
extension MCPDataStore {

    func generateExplainerVideo(arguments: [String: Any]) async throws -> String {
        let concept = (arguments["concept"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty else {
            throw MCPError.invalidInput("concept is required.")
        }
        let length: ExplainerVideoLength
        if let name = (arguments["length"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty {
            guard let parsed = ExplainerVideoLength(rawValue: name) else {
                throw MCPError.invalidInput(
                    "length must be one of \(ExplainerVideoLength.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            length = parsed
        } else {
            length = .default
        }

        // Read through the storage actor: this tool waits on the learner's
        // price dialog holding no store gate (`storeGateExemptToolNames`).
        let sourceID = ((arguments["source_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        if let sourceID {
            guard let source = try await notebookFileStorage.loadPersistedSources(ids: [sourceID]).first,
                  source.status == .active else {
                throw MCPError.invalidInput("Source not found: \(sourceID)")
            }
            guard ExplainerVideoGeneratorService.groundingSourceTypes.contains(source.sourceType),
                  !GeneratedExplainer.isSpokenScriptURL(source.url) else {
                throw MCPError.invalidInput("A video can be grounded on a paper or an article; '\(source.title)' is a \(source.sourceType.rawValue). Leave source_id out to film the concept on its own.")
            }
        }
        let lectureID = ((arguments["lecture_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        var lectureTitle: String?
        if let lectureID {
            guard let lecture = try await notebookFileStorage.loadCourseLectures().first(where: { $0.id == lectureID }) else {
                throw MCPError.invalidInput("Lecture not found: \(lectureID). Use a lecture_id from generate_course or get_course.")
            }
            lectureTitle = lecture.title ?? "Lecture \(lecture.number)"
        }

        // The notebook the finished video joins, checked before the price is
        // asked (docs/notebooks-design.md, "Homing"). The video is a source,
        // so joining the notebook's pool is its home there.
        let notebook = try await notebookForMadeThing(notebookID: arguments["notebook_id"] as? String)

        let request = ExplainerVideoRequest(concept: concept, sourceID: sourceID, length: length)
        let job = try await Self.startExplainerVideo(request, lectureID: lectureID, notebookID: notebook?.id)

        guard let job else {
            return try jsonString([
                "status": "declined",
                "concept": concept,
                "message": "The learner declined the price in ForeverLM's dialog, or the video model is unavailable or has no price at the chosen resolution (the dialog said which). Nothing was filmed or billed.",
            ])
        }
        var payload: [String: Any] = [
            "status": "started",
            "job_id": job.id,
            "work_id": "video-\(job.id)",
            "concept": concept,
            "length": length.rawValue,
            "seconds": length.seconds(clipSeconds: job.model.clipSeconds),
            "model": job.model.name,
            "resolution": job.resolution.displayName,
        ]
        if let cost = GeneratedExplainerVideo.estimatedCostUSD(length: length, model: job.model, resolution: job.resolution) {
            payload["estimated_cost_usd"] = cost
        }
        if let lectureID, let lectureTitle {
            payload["lecture_id"] = lectureID
            payload["message"] = "Filming in the background; it takes a few minutes. The finished video is added to '\(lectureTitle)' as its video. The learner can follow or cancel it under Videos, and cancel_ai_work with this work_id stops it from here."
        } else {
            payload["message"] = "Filming in the background; it takes a few minutes. The finished video appears under Videos, where the learner can follow or cancel it; cancel_ai_work with this work_id stops it from here."
        }
        if let notebook {
            payload["notebook_id"] = notebook.id
            payload["notebook_note"] = "The finished video joins Notebook ‘\(notebook.title)’ as one of its sources."
        }
        return try jsonString(payload)
    }

    @MainActor
    private static func startExplainerVideo(
        _ request: ExplainerVideoRequest,
        lectureID: String?,
        notebookID: String?
    ) async throws -> ExplainerVideoGenerationCoordinator.Job? {
        let studio = try AppModelBridge.requireStudio()
        return await ExplainerVideoGenerationCoordinator.shared.start(request, in: studio, lectureID: lectureID, notebookID: notebookID)
    }
}
#endif
