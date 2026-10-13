import PDFKit
import SwiftUI

/// The reference card a citation shows in the phone's PDF reader: tapping a
/// superscript like ³³ reads what paper 33 is where it is cited, instead of
/// jumping to the reference list, and offers to open it or add it (product owner,
/// 2026-09-25, after the Mac's card: "just do what you think makes sense").
///
/// The entry is read from the paper's own file by the Mac's
/// `PDFReferenceEntries`, so every publisher layout the Mac handles reads the
/// same here. A link with nothing to show — a figure, a page link — still goes
/// where it lands.
@MainActor
final class MobileReaderReferenceCards: ObservableObject {
    @Published var card: MobileReaderReferenceCard?
    /// The file the shown document was opened from. A chapter kept as a run of
    /// its book's pages is shown as those pages alone, so its links are read
    /// from the book at the book's page numbers, and a landing is gone to only
    /// when it is one of the chapter's pages.
    var file: MobileSourcePDF?

    private weak var pdfView: MobileHighlightPDFView?
    private var entries: (url: URL, entries: PDFReferenceEntries)?
    private var pending: Task<Void, Never>?

    func attach(to pdfView: MobileHighlightPDFView) {
        self.pdfView = pdfView
        pdfView.onTapInternalLink = { [weak self] annotation in
            self?.tapped(annotation) ?? false
        }
    }

    /// Takes every link within a document opened from its file, so PDFKit
    /// never jumps first.
    private func tapped(_ annotation: PDFAnnotation) -> Bool {
        guard let pdfView, let document = pdfView.document, let file,
              let page = annotation.page else { return false }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return false }
        let firstPage = file.pages?.lowerBound ?? 0
        let entries = entries(for: file.url)
        let link = PDFReferenceEntries.Link(pageIndex: firstPage + pageIndex, bounds: annotation.bounds)
        let anchor = pdfView.convert(annotation.bounds, from: page)
        pending?.cancel()
        pending = Task { [weak self] in
            if let text = await entries.entry(for: link) {
                guard !Task.isCancelled, let self else { return }
                self.card = MobileReaderReferenceCard(text: text, anchor: anchor)
                return
            }
            let landing = await entries.landing(for: link)
            guard !Task.isCancelled, let self, let pdfView = self.pdfView, pdfView.document === document else { return }
            let landingIndex = landing.map { $0.pageIndex - firstPage }
            if let landing, let landingIndex, (0..<document.pageCount).contains(landingIndex),
               let page = document.page(at: landingIndex) {
                pdfView.followLink(to: PDFDestination(page: page, at: landing.point))
            } else if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                      let target = destination.page, document.index(for: target) != NSNotFound {
                // Only a page of this document: a chapter's copied links can
                // name pages of its book that are not shown here.
                pdfView.followLink(to: destination)
            }
        }
        return true
    }

    private func entries(for url: URL) -> PDFReferenceEntries {
        if let entries, entries.url == url { return entries.entries }
        let made = PDFReferenceEntries(.file(url))
        entries = (url, made)
        return made
    }
}

/// A library paper a citation's card opened, pushed as its own reader.
struct MobileCitedSourceDestination: Hashable {
    let source: MobileCloudSource

    static func == (lhs: MobileCitedSourceDestination, rhs: MobileCitedSourceDestination) -> Bool {
        lhs.source.id == rhs.source.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.id)
    }
}

struct MobileReaderReferenceCard: Identifiable {
    let id = UUID()
    let text: String
    /// The citation's rectangle in the PDF view, for the popover's arrow.
    let anchor: CGRect
}

struct MobileReaderReferenceCardView: View {
    let card: MobileReaderReferenceCard
    let open: (MobileCloudSource) -> Void

    @EnvironmentObject private var audio: MobileAudioReviewViewModel
    @State private var status: Status = .checking

    private enum Status {
        case checking
        /// Nothing the card can open or add: an affiliation, a caption, a
        /// work that prints no DOI and no title the library holds.
        case notAPaper
        case inLibrary(MobileCloudSource)
        case absent(URL)
        case adding
        case added
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                Text(card.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                footer
            }
            .padding(MobileDesign.Spacing.large)
        }
        .frame(idealWidth: 360)
        .task(id: card.id) { status = resolvedStatus() }
    }

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .checking, .notAPaper:
            EmptyView()
        case .inLibrary(let source):
            Button {
                open(source)
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }
            .buttonStyle(.borderedProminent)
        case .absent(let url):
            Button {
                Task { await add(url) }
            } label: {
                Label("Add to Library", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        case .adding:
            HStack(spacing: MobileDesign.Spacing.small) {
                ProgressView()
                Text("Adding…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .added:
            // The phone queues the paper; the Mac fetches and imports it.
            Label("Added. Your Mac downloads the paper next time ForeverLM runs there.", systemImage: "checkmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// The library source the entry names, else the DOI address to add it by.
    private func resolvedStatus() -> Status {
        let candidates = audio.allSources.map { source in
            PDFReferenceEntries.LibraryCandidate(
                id: source.id,
                dois: [source.doi, source.publishedDOI].compactMap { $0 },
                title: source.title
            )
        }
        if let id = PDFReferenceEntries.librarySourceID(forEntry: card.text, in: candidates),
           let source = audio.allSources.first(where: { $0.id == id }) {
            return .inLibrary(source)
        }
        if let doi = PDFReferenceEntries.doi(inReferenceEntry: card.text),
           let url = URL(string: "https://doi.org/\(doi)") {
            return .absent(url)
        }
        return .notAPaper
    }

    private func add(_ url: URL) async {
        status = .adding
        if await audio.captureSource(url: url, title: nil, sourceType: "paper") != nil {
            status = .added
        } else {
            status = .failed(audio.errorMessage ?? "The paper could not be added.")
        }
    }
}
