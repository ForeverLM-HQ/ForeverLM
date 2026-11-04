import PDFKit

extension ReaderPDFReferencePreview {
    /// Gives the citation card what it needs to save a highlight of a
    /// reference entry's words, as the reader saves a highlight of any other
    /// selection: the words are the page's own, so the highlight is a
    /// highlight on the PDF's reference list, in the source whose pages those
    /// are, and shows there too and the next time the card opens. It is the
    /// reader's own highlight (`source_highlights`: per member, text anchor
    /// plus page quads), not a record of the card's.
    ///
    /// - Parameters:
    ///   - sourceID: the source the whole document is, when it is not a book.
    ///   - sections: the sources of a book assembled from chapters, by page.
    func configureHighlighting(viewModel: StudioViewModel, sourceID: String, sections: [PDFDocumentSection]?) {
        func sectionContaining(page index: Int, of pageCount: Int) -> PDFDocumentSection? {
            (sections ?? [PDFDocumentSection(sourceID: sourceID, pageRange: 0..<pageCount)])
                .first { $0.pageRange.contains(index) }
        }
        sourceIDOfPage = { index in
            guard let sections else { return sourceID }
            return sections.first { $0.pageRange.contains(index) }?.sourceID
        }
        saveHighlight = { [weak viewModel] selection, color in
            guard let viewModel, let page = selection.pages.first, let document = page.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound, let section = sectionContaining(page: index, of: document.pageCount),
                  let anchors = ReaderPDFHighlightSupport.anchors(for: selection, in: document, pageRange: section.pageRange)
            else { return }
            let quote = selection.string ?? ""
            let owner = section.sourceID
            Task { @MainActor in
                await viewModel.highlightReaderSelection(
                    sourceID: owner,
                    quote: quote,
                    anchor: anchors.text,
                    pdfAnchor: anchors.pdf,
                    color: color,
                    opensCard: false
                )
            }
        }
    }
}
