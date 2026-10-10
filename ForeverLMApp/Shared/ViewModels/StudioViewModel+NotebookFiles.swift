import Foundation

extension StudioViewModel {
    func notebookFiles(notebookID: String) -> [NotebookFileRecord] {
        notebookFilesByNotebookID[notebookID] ?? []
    }

    /// Refreshes from the Notebook directory. Activation-triggered calls use a
    /// short cooldown so switching between apps cannot launch redundant scans.
    func refreshNotebookFiles(notebookID: String, force: Bool = false) async {
        guard notebook(id: notebookID)?.isNotebook == true else { return }
        guard !notebookFileRefreshesInFlight.contains(notebookID) else { return }
        if !force,
           let lastRefresh = notebookFilesLastRefreshAt[notebookID],
           Date().timeIntervalSince(lastRefresh) < 2 {
            return
        }

        notebookFileRefreshesInFlight.insert(notebookID)
        defer { notebookFileRefreshesInFlight.remove(notebookID) }
        do {
            let records = try await storage.loadNotebookFiles(notebookID: notebookID)
            notebookFilesByNotebookID[notebookID] = records
            notebookFilesLastRefreshAt[notebookID] = Date()
        } catch {
            logger.error("Refreshing Notebook files failed: \(error.localizedDescription)")
        }
    }

    func importNotebookFiles(
        notebookID: String,
        urls: [URL]
    ) async {
        guard !urls.isEmpty else { return }
        do {
            let records = try await storage.importNotebookFiles(
                notebookID: notebookID,
                urls: urls
            )
            notebookFilesByNotebookID[notebookID] = records
            notebookFilesLastRefreshAt[notebookID] = Date()
            showToast(urls.count == 1 ? "Added a file to the notebook" : "Added \(urls.count) files to the notebook")
        } catch {
            logger.error("Importing Notebook files failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showToast("Could not add the files to the notebook")
        }
    }

    func createNotebookMarkdownFile(
        notebookID: String,
        preferredRelativePath: String
    ) async throws -> NotebookMarkdownFileSnapshot {
        let snapshot = try await storage.createNotebookMarkdownFile(
            notebookID: notebookID,
            preferredRelativePath: preferredRelativePath
        )
        let records = try await storage.loadNotebookFiles(notebookID: notebookID)
        notebookFilesByNotebookID[notebookID] = records
        notebookFilesLastRefreshAt[notebookID] = Date()
        showToast("Created \(snapshot.record.name)")
        return snapshot
    }

    func notebookMarkdownFile(
        notebookID: String,
        relativePath: String
    ) async throws -> NotebookMarkdownFileSnapshot {
        try await storage.notebookMarkdownFile(
            notebookID: notebookID,
            relativePath: relativePath
        )
    }

    func saveNotebookMarkdownFile(
        notebookID: String,
        relativePath: String,
        markdown: String,
        expectedRevision: String
    ) async throws -> NotebookMarkdownFileSnapshot {
        let snapshot = try await storage.writeNotebookMarkdownFile(
            notebookID: notebookID,
            relativePath: relativePath,
            markdown: markdown,
            expectedRevision: expectedRevision
        )
        let records = try await storage.loadNotebookFiles(notebookID: notebookID)
        notebookFilesByNotebookID[notebookID] = records
        notebookFilesLastRefreshAt[notebookID] = Date()
        return snapshot
    }

    func removeNotebookFile(_ record: NotebookFileRecord) async {
        do {
            let records = try await storage.removeNotebookFile(record)
            notebookFilesByNotebookID[record.notebookID] = records
            notebookFilesLastRefreshAt[record.notebookID] = Date()
            showToast("Moved the notebook's file to the Trash")
        } catch {
            logger.error("Removing Notebook file failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func notebookFilePreview(_ record: NotebookFileRecord) async -> NotebookFilePreview {
        do {
            return try await storage.notebookFilePreview(for: record)
        } catch {
            logger.error("Preparing Notebook file preview failed: \(error.localizedDescription)")
            return .unavailable(message: error.localizedDescription)
        }
    }

    func notebookFileURL(_ record: NotebookFileRecord) async -> URL {
        await storage.notebookFileURL(for: record)
    }

    func notebookWorkspaceURL(notebookID: String) async -> URL? {
        do {
            return try await storage.notebookWorkspaceURL(notebookID: notebookID)
        } catch {
            logger.error("Opening Notebook workspace failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
