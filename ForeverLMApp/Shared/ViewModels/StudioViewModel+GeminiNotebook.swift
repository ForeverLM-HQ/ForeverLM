import Foundation
import OSLog

/// Gemini notebooks: a notebook link becomes a Notebook holding what
/// the notebook held (docs-site/studio.md, "Importing a Gemini Notebook"). Its
/// sources join the library — a web page or a video by its address, so the app
/// reads and types it as it does a pasted link; a Google Doc linked in Docs;
/// anything the notebook held only as text kept as that text — each of its
/// chats becomes a chat filed under the Notebook and linked to those sources,
/// and its notes and written reports become Docs in the Notebook. What ForeverLM
/// has no place for (audio and video overviews, flashcards, quizzes, mind maps,
/// apps) is named in the result and stays in the notebook.
///
/// The reading is `GeminiNotebookService`'s and happens whole before anything
/// is filed, so a notebook that cannot be read leaves the library as it was.
/// Importing the same notebook again files only what is new: a source is found
/// by its address, a chat by its conversation's id (and brought level with the
/// notebook's), a Doc by its title in the Notebook. A Doc is never overwritten,
/// so an imported note the learner has since edited keeps the edits.
extension StudioViewModel {
    struct GeminiNotebookImport: Equatable, Sendable {
        var notebookID: String
        var notebookTitle: String
        var createdNotebook: Bool
        var addedSourceIDs: [String] = []
        var existingSourceIDs: [String] = []
        var linkedDocIDs: [String] = []
        var chats: [StorageService.ImportedChatOutcome] = []
        var docIDs: [String] = []
        var keptDocTitles: [String] = []
        var leftBehind: [String] = []
        var failures: [String] = []

        var sourceIDs: [String] { addedSourceIDs + existingSourceIDs }

        /// One line for the toast and the tool's answer.
        var summary: String {
            var parts: [String] = []
            let sourceCount = sourceIDs.count
            if sourceCount > 0 { parts.append("\(sourceCount) source\(sourceCount == 1 ? "" : "s")") }
            if !chats.isEmpty { parts.append("\(chats.count) chat\(chats.count == 1 ? "" : "s")") }
            let docCount = docIDs.count + linkedDocIDs.count
            if docCount > 0 { parts.append("\(docCount) page\(docCount == 1 ? "" : "s")") }
            let held = parts.isEmpty ? "nothing new" : parts.joined(separator: ", ")
            return "Imported “\(notebookTitle)”: \(held)"
        }
    }

    /// Doc titles cap where Notebook titles do.
    private nonisolated static let geminiNotebookTitleLimit = 90

    /// Import the notebook a link names into a Notebook: the one given, else
    /// the Notebook that already has the notebook's title, else a new one.
    /// Returns nil with `errorMessage` saying why when the notebook could not
    /// be read or the Notebook not made; a source, chat or note that could not
    /// be filed is named in `failures` and the rest is filed.
    @discardableResult
    func importGeminiNotebook(
        url: String,
        intoNotebook requestedNotebookID: String? = nil,
        revealNotebook: Bool = true
    ) async -> GeminiNotebookImport? {
        // The window the link was pasted in: the import takes a while, and
        // the notebook opens there when it lands, not in whichever window is
        // key by then.
        let originWindow = activeWindowState
        urlInput = ""
        playlistImportBannerHidden = false
        playlistImportStatus = "Reading the notebook…"
        defer { playlistImportStatus = nil }

        guard let notebookID = GeminiNotebookService.notebookID(in: url) else {
            errorMessage = GeminiNotebookService.GeminiNotebookError.notANotebookLink.localizedDescription
            return nil
        }
        let export: GeminiNotebookService.NotebookExport
        do {
            export = try await GeminiNotebookService.readNotebook(id: notebookID)
        } catch {
            logger.warning("Gemini Notebook \(notebookID, privacy: .public) could not be read: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return nil
        }

        let notebookTitle = Self.geminiNotebookTitle(export.title, fallback: GeminiNotebookService.productName)
        playlistImportStatus = "Importing “\(notebookTitle)”…"

        let notebook: LearningGoalRecord
        let createdNotebook: Bool
        if let requestedNotebookID = requestedNotebookID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedNotebookID.isEmpty {
            guard let requested = self.notebook(id: requestedNotebookID), requested.isNotebook else {
                errorMessage = "No notebook with id \(requestedNotebookID)."
                return nil
            }
            notebook = requested
            createdNotebook = false
        } else if let existing = notebooks.first(where: { $0.isNotebook && !$0.isArchived && $0.title == notebookTitle }) {
            notebook = existing
            createdNotebook = false
        } else {
            guard let created = await createNotebookContext(title: notebookTitle) else {
                errorMessage = "The notebook for “\(notebookTitle)” could not be made."
                return nil
            }
            notebook = created
            createdNotebook = true
        }

        var result = GeminiNotebookImport(notebookID: notebook.id, notebookTitle: notebook.title, createdNotebook: createdNotebook)
        await fileGeminiNotebookSources(export, into: notebook.id, result: &result)
        if !result.sourceIDs.isEmpty {
            await addSourcesToNotebookContext(result.sourceIDs, notebookID: notebook.id)
        }
        await fileGeminiNotebookChats(export, title: notebookTitle, into: notebook.id, result: &result)
        await fileGeminiNotebookNotes(export, into: notebook.id, result: &result)
        result.leftBehind += export.leftBehind.map { item in
            item.title.isEmpty ? item.kind : "\(item.title) (\(item.kind))"
        }

        NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        // The import finishes in the background, so the notebook opens around
        // whatever chat the learner is in by then, never swapping it for a
        // fresh one; an empty chat joins the notebook by itself.
        if revealNotebook { openNotebook(notebook.id, in: originWindow, startsNotebookChat: false) }
        showToast(result.summary)
        logger.info("Imported Gemini Notebook \(notebookID, privacy: .public) into Notebook \(notebook.id, privacy: .public): \(result.sourceIDs.count) sources, \(result.chats.count) chats, \(result.docIDs.count) docs, \(result.failures.count) failures")
        return result
    }

    // MARK: - Sources

    private func fileGeminiNotebookSources(
        _ export: GeminiNotebookService.NotebookExport,
        into notebookID: String,
        result: inout GeminiNotebookImport
    ) async {
        for source in export.sources {
            let label = source.title.isEmpty ? "A source" : "“\(source.title)”"
            switch source.route {
            case .address(let address):
                if let index = existingArticleIndex(matchingSourceURL: address) {
                    result.existingSourceIDs.append(articles[index].id)
                    continue
                }
                // The source bar's own route, so the app reads, types and
                // (for a paper) fetches the PDF as it does for a pasted link.
                // Its refusals arrive through `errorMessage`, which is put
                // back afterwards so the import's own outcome is what shows.
                let earlierError = errorMessage
                errorMessage = nil
                do {
                    try await addArticle(url: address, revealInReader: false)
                } catch {
                    errorMessage = error.localizedDescription
                }
                if let index = existingArticleIndex(matchingSourceURL: address) {
                    result.addedSourceIDs.append(articles[index].id)
                } else {
                    result.failures.append("\(label): \(errorMessage ?? "it could not be added.")")
                }
                errorMessage = earlierError
            case .googleDoc(let documentID):
                do {
                    let linked = try await linkPage(
                        urlString: LinkedGoogleDoc.editURL(documentID: documentID).absoluteString,
                        homeNotebookID: notebookID,
                        linkedNotebookIDs: [notebookID]
                    )
                    result.linkedDocIDs.append(linked.id)
                } catch {
                    result.failures.append("\(label): \(error.localizedDescription)")
                }
            case .text(let text):
                let address = GeminiNotebookService.sourceAddress(notebookID: export.notebookID, sourceID: source.id)
                if let index = existingArticleIndex(matchingSourceURL: address) {
                    result.existingSourceIDs.append(articles[index].id)
                    continue
                }
                var article = StudioArticle(
                    url: address,
                    title: source.title.isEmpty ? GeminiNotebookService.productName : source.title,
                    sourceType: .article,
                    discoveryOrigin: .manual
                )
                article.domain = GeminiNotebookService.productName
                article.content = text
                article.wordCount = text.split(separator: " ").count
                article.state = .ready
                do {
                    if try await storage.insertSourceIfNew(&article) {
                        articles.insert(article, at: 0)
                        result.addedSourceIDs.append(article.id)
                    } else {
                        result.failures.append("\(label): it was removed from the library before, so it was not added again.")
                    }
                } catch {
                    result.failures.append("\(label): \(error.localizedDescription)")
                }
            case .empty:
                result.leftBehind.append("\(source.title.isEmpty ? "A source" : source.title) (no text in the notebook)")
            }
        }
    }

    // MARK: - Chats

    private func fileGeminiNotebookChats(
        _ export: GeminiNotebookService.NotebookExport,
        title notebookTitle: String,
        into notebookID: String,
        result: inout GeminiNotebookImport
    ) async {
        let chats = export.chats.filter(\.hasLearnerMessage)
        for (index, chat) in chats.enumerated() {
            let title = index == 0 ? notebookTitle : "\(notebookTitle) (\(index + 1))"
            do {
                let outcome = try await storage.saveImportedChat(
                    // The conversation's own id, so a second import finds it.
                    id: chat.conversationID.uppercased(),
                    title: title,
                    messages: chat.messages,
                    sourceIDs: result.sourceIDs,
                    notebookID: notebookID,
                    modelProvider: GeminiNotebookService.productName
                )
                result.chats.append(outcome)
            } catch {
                result.failures.append("Chat “\(title)”: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Notes

    private func fileGeminiNotebookNotes(
        _ export: GeminiNotebookService.NotebookExport,
        into notebookID: String,
        result: inout GeminiNotebookImport
    ) async {
        guard !export.notes.isEmpty else { return }
        let titles = Self.geminiNotebookDocTitles(for: export.notes)
        let heldTitles = Set(artifacts
            .filter { $0.homeNotebookID == notebookID || $0.linkedNotebookIDs.contains(notebookID) }
            .map(\.title))
        for (note, title) in zip(export.notes, titles) {
            if heldTitles.contains(title) {
                result.keptDocTitles.append(title)
                continue
            }
            do {
                let snapshot = try await storage.createArtifact(
                    title: title,
                    homeNotebookID: notebookID,
                    linkedNotebookIDs: [notebookID],
                    markdown: note.markdown,
                    teamID: activeTeamID
                )
                result.docIDs.append(snapshot.artifact.id)
            } catch {
                result.failures.append("Note “\(title)”: \(error.localizedDescription)")
            }
        }
        do {
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Reloading Docs after a Gemini Notebook import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Each note's Doc title: its own, or "Note" for an untitled one, with a
    /// number after the second and later notes of one title, so two notes
    /// never share a Doc and a second import finds each by the same name.
    nonisolated static func geminiNotebookDocTitles(for notes: [GeminiNotebookService.NotebookNote]) -> [String] {
        var seen: [String: Int] = [:]
        return notes.map { note in
            let base = geminiNotebookTitle(note.title, fallback: "Note")
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            return count == 1 ? base : "\(base) (\(count))"
        }
    }

    nonisolated static func geminiNotebookTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(geminiNotebookTitleLimit))
    }
}
