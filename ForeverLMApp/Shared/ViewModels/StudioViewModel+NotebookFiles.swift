import Foundation

extension StudioViewModel {
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
}
