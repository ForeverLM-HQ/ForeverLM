import AppKit
import WebKit

extension StudioViewModel {
    /// The learner asked for the reader's page as a paper's text
    /// (**Save Paper from Page**) and the paper has no PDF. A paper is a PDF,
    /// so: ask the publisher for the file once more with the session the page
    /// was read in — a sign-in on that page is usually what changed since the
    /// download was refused — and when the file is still refused, print the
    /// page the learner is reading.
    func attachPDFForAdoptedPaperPage(articleId: String, printing webView: WKWebView) async {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper,
              article.resolvedPDFPath == nil else { return }

        if let remotePDFURL = article.remotePDFURL,
           case .success(let data) = await RemotePDFLoader.fetch(remotePDFURL) {
            do {
                try await attachDownloadedPDFData(to: articleId, data: data, sourceURL: remotePDFURL)
            } catch {
                logger.info("The publisher's PDF for \(article.title) could not be saved: \(error.localizedDescription)")
            }
            if paperHasLocalPDF(articleId) { return }
        }

        do {
            let data = try await PublisherPagePDFRenderer.printPDF(from: webView)
            await attachRenderedPublisherPagePDF(to: articleId, data: data)
        } catch {
            logger.warning("Could not print the page open for \(article.title) to a PDF: \(error.localizedDescription)")
            showToast("Saved the paper's text, but the page could not be printed to a PDF")
        }
    }
}
