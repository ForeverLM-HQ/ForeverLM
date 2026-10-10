import Foundation

extension MCPDataStore {

    // MARK: - Gemini Notebook

    /// Import a Gemini Notebook the way pasting its link does
    /// (`StudioViewModel.importGeminiNotebook`): the notebook read whole as the
    /// learner signed in inside ForeverLM, then filed as a Notebook with its
    /// sources, chats and notes. Returns once everything is filed; a web
    /// source's own text is read by the app afterwards, as for a pasted link.
    func importGeminiNotebookMCP(url rawURL: String, notebookID rawNotebookID: String?) async throws -> String {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GeminiNotebookService.isNotebookURL(url) else {
            throw MCPError.invalidInput(
                "url must be a Gemini Notebook address (https://notebook.google.com/notebook/<id>). Open the notebook and pass its address."
            )
        }
        let notebookID = Self.nilIfBlank(rawNotebookID ?? "")
        return try jsonString(try await Self.importGeminiNotebookLikeThePasteField(url: url, notebookID: notebookID))
    }

    @MainActor
    private static func importGeminiNotebookLikeThePasteField(url: String, notebookID: String?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        studio.errorMessage = nil
        guard let result = await studio.importGeminiNotebook(url: url, intoNotebook: notebookID, revealNotebook: false) else {
            throw MCPError.invalidInput(studio.errorMessage ?? "The notebook could not be imported.")
        }
        let chats: [[String: Any]] = result.chats.map { chat in
            [
                "session_id": chat.sessionID,
                "created": chat.created,
                "exchanges_added": chat.appended,
                "exchanges_rewritten": chat.replaced,
            ]
        }
        var payload: [String: Any] = [
            "notebook_id": result.notebookID,
            "notebook_title": result.notebookTitle,
            "created_notebook": result.createdNotebook,
            "added_source_ids": result.addedSourceIDs,
            "existing_source_ids": result.existingSourceIDs,
            "linked_doc_ids": result.linkedDocIDs,
            "chats": chats,
            "doc_ids": result.docIDs,
            "message": "\(result.summary). Web pages and videos are read by the app in the background, as a pasted link is; the chats are saved as chats (not reviews) under the Notebook and linked to its sources.",
        ]
        if !result.keptDocTitles.isEmpty {
            payload["kept_doc_titles"] = result.keptDocTitles
        }
        if !result.leftBehind.isEmpty {
            payload["left_in_notebook"] = result.leftBehind
        }
        if !result.failures.isEmpty {
            payload["failures"] = result.failures
        }
        return payload
    }

    // MARK: - Video overviews

    /// Bring a video file into the library and a Notebook the way the Studio's
    /// Video overview tile does (`StudioViewModel.importVideoOverview`): copied
    /// in as a video source, then filed in the Notebook when one is named.
    func importVideoOverviewMCP(filePath: String, notebookID rawNotebookID: String?) async throws -> String {
        let fileURL = try validateClientProvidedPath(filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MCPError.invalidInput("File not found: \(filePath)")
        }
        guard VideoOverviewImporter.canImport(fileURL) else {
            throw MCPError.invalidInput("file_path must be an MP4, M4V or MOV video: \(filePath)")
        }
        let notebookID = Self.nilIfBlank(rawNotebookID ?? "")
        return try jsonString(try await Self.importVideoOverviewLikeTheStudio(fileURL: fileURL, notebookID: notebookID))
    }

    @MainActor
    private static func importVideoOverviewLikeTheStudio(fileURL: URL, notebookID: String?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        if let notebookID, studio.importableNotebook(notebookID) == nil {
            throw MCPError.invalidInput("notebook_id \(notebookID) is not a Notebook that takes new sources (list_notebooks names them; an archived Notebook or a team's the learner can only read does not).")
        }
        let outcome = await studio.importVideoOverview(at: fileURL, intoNotebook: notebookID)
        let library: String
        switch outcome.library {
        case .added: library = "added"
        case .alreadyHeld: library = "already_in_library"
        case .linkedPage: library = "linked"
        case .failed(let reason): throw MCPError.invalidInput(reason)
        }
        var payload: [String: Any] = [
            "source_id": outcome.sourceID ?? "",
            "library": library,
        ]
        switch outcome.membership {
        case .none: payload["notebook"] = "not requested"
        case .added: payload["notebook"] = "added"
        case .alreadyIn: payload["notebook"] = "already_in_notebook"
        case .failed(let reason): payload["notebook"] = "failed: \(reason)"
        }
        payload["message"] = "The video is a source in the library; open it in the Reader to play it. It has no transcript."
        return payload
    }
}
