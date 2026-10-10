import Foundation

/// Answering a journal suggestion: "include this in your sources?"
extension StudioViewModel {

    /// Yes. The article enters the library through the same path as a pasted
    /// URL — PDF resolution, the publisher's own download through the reader's
    /// session, metadata — and joins the Notebook's pool. An article the
    /// library already holds is simply added to the Notebook.
    func acceptJournalSuggestion(_ suggestion: JournalArticleSuggestion) async {
        let url = suggestion.item.itemURL
        var sourceID = existingSourceID(matchingURL: url, doi: suggestion.item.doi)
        if sourceID == nil {
            do {
                try await addArticle(url: url, revealInReader: false)
            } catch {
                logger.error("Journal suggestion could not be added: \(error.localizedDescription, privacy: .public)")
                showToast("Could not add “\(suggestion.item.title)”")
                return
            }
            sourceID = existingSourceID(matchingURL: url, doi: suggestion.item.doi)
        }
        guard let sourceID else {
            // addArticle reports duplicates and removals through errorMessage
            // rather than throwing; say what it said.
            showToast(errorMessage ?? "Could not add “\(suggestion.item.title)”")
            return
        }
        await addSourcesToNotebookContext([sourceID], notebookID: suggestion.match.notebookID)
        do {
            try await storage.setJournalMatchState(
                itemURL: suggestion.match.itemURL,
                notebookID: suggestion.match.notebookID,
                state: .accepted,
                sourceID: sourceID
            )
        } catch {
            logger.error("Journal suggestion could not be marked accepted: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: .journalWatchDidChange, object: nil)
    }

    /// No. A tombstone, so the same article is never offered to this Notebook
    /// again; other Notebooks it matched keep their own suggestion.
    func dismissJournalSuggestion(_ suggestion: JournalArticleSuggestion) async {
        do {
            try await storage.setJournalMatchState(
                itemURL: suggestion.match.itemURL,
                notebookID: suggestion.match.notebookID,
                state: .dismissed
            )
        } catch {
            logger.error("Journal suggestion could not be dismissed: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: .journalWatchDidChange, object: nil)
    }

    /// The banner's click: the Notebook, opened on its source pool.
    func openNotebookJournalSuggestions(notebookID: String?) {
        guard let notebookID, notebook(id: notebookID) != nil else {
            showSpaceAll()
            return
        }
        pendingNotebookSourcesRequestID = notebookID
        openNotebookInReader(notebookID)
    }

    /// The library source an announced article already is, by URL or DOI.
    ///
    /// The DOI may sit only in an address — a `doi.org` link, a publisher URL
    /// with the DOI as its path — on either side, so both are read the way
    /// `addArticle`'s duplicate check reads them; otherwise an accepted article
    /// the library already holds would be refused as a duplicate and the
    /// suggestion left pending.
    func existingSourceID(matchingURL url: String, doi: String?) -> String? {
        let normalizedURL = URLNormalizer.normalize(url)
        let normalizedDOI = (doi ?? PaperService.extractDOI(from: url)).map(Self.normalizeDOI)
        return articles.first { article in
            if article.url == url || URLNormalizer.normalize(article.url) == normalizedURL { return true }
            guard let normalizedDOI, !normalizedDOI.isEmpty else { return false }
            if let articleDOI = article.doi, Self.normalizeDOI(articleDOI) == normalizedDOI { return true }
            if let urlDOI = PaperService.extractDOI(from: article.url), Self.normalizeDOI(urlDOI) == normalizedDOI { return true }
            return false
        }?.id
    }
}
