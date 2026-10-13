import PDFKit
import SwiftUI
import UIKit

private actor MobilePaperFigureRenderer {
    static let shared = MobilePaperFigureRenderer()

    /// The widest a crop is drawn, in pixels: sharp at full screen on a
    /// phone and pinch-zoomed a few times, without drawing a whole page at
    /// that density.
    private static let cropPixelWidth: CGFloat = 1_600
    private static let maximumScale: CGFloat = 8

    /// The figure, or its panel, drawn from the PDF. The region is the one
    /// the Mac's vision analysis measured when there is one; otherwise it is
    /// found here from the page itself, the way the Mac finds it for a figure
    /// it has not analysed — the figure's ink above or below its printed
    /// caption (`PaperFigureRectRefiner`), and a panel's box from the bold
    /// letter the figure prints for it (`PaperFigurePanelLocator`). A page
    /// neither finds anything on is drawn whole.
    func image(
        for figure: SyncedPaperFigure,
        panel: PaperFigurePanel? = nil,
        panelLabel: String? = nil,
        sharesPageWithOtherFigures: Bool = false,
        relativePDFPath: String? = nil
    ) async throws -> UIImage {
        let pdf = try await MobileSourceFileStore.shared.fetchPDF(
            sourceID: figure.sourceID,
            relativePath: relativePDFPath
        )
        let pageIndex = figure.pageIndex
        let measuredPanel = panel?.rect.flatMap { $0.isValid ? $0 : nil }
        let panelID = panel?.id
        let measuredPanels: [String: PaperFigureRect] = (figure.analysis?.panels ?? []).reduce(into: [:]) { result, other in
            if let rect = other.rect, rect.isValid { result[other.id] = rect }
        }
        let measuredFigure = figure.analysis?.figureRect.flatMap { $0.isValid ? $0 : nil }
        let caption = figure.caption
        let wantedPanel = panelLabel ?? panel?.label
        return try await Task.detached(priority: .userInitiated) {
            // A book chapter's figure counts its page from the chapter's first
            // page, which is the chapter document's page 0.
            let document = try pdf.document()
            guard let page = document.page(at: pageIndex) else {
                throw MobileSourceFileError.noPDFAvailable
            }
            return withExtendedLifetime(document) {
                let figureRect = measuredFigure ?? PaperFigureRectRefiner.figureCrop(
                    forCaption: caption,
                    on: page,
                    sharesPageWithOtherFigures: sharesPageWithOtherFigures
                )
                var region = measuredPanel
                // An analysis stored before overlapping panels were split at
                // their gutter can carry the next panel's heading along this
                // one's foot; the page is only read when the box overlaps one.
                if let measuredPanel, let panelID,
                   measuredPanels.contains(where: { $0.key != panelID && Self.overlaps($0.value, measuredPanel) }),
                   let mask = PaperFigureRectRefiner.mask(for: page) {
                    region = PaperFigureRectRefiner.separatedPanelRects(measuredPanels, with: mask)[panelID] ?? measuredPanel
                }
                if region == nil, let wantedPanel, let figureRect {
                    region = PaperFigurePanelLocator.panelRect(labelled: wantedPanel, in: figureRect, on: page)
                }
                if let rect = region ?? figureRect, let image = Self.render(rect, on: page) {
                    return image
                }
                return page.thumbnail(of: CGSize(width: 1_600, height: 2_100), for: .mediaBox)
            }
        }.value
    }

    private static func overlaps(_ lhs: PaperFigureRect, _ rhs: PaperFigureRect) -> Bool {
        lhs.x < rhs.x + rhs.width && rhs.x < lhs.x + lhs.width
            && lhs.y < rhs.y + rhs.height && rhs.y < lhs.y + lhs.height
    }

    /// `rect` (normalised, top-left origin, in the page's media box) drawn
    /// at `cropPixelWidth`, on white.
    private static func render(_ rect: PaperFigureRect, on page: PDFPage) -> UIImage? {
        guard rect.isValid else { return nil }
        let box = page.bounds(for: .mediaBox)
        let region = CGRect(
            x: box.minX + rect.x * box.width,
            y: box.maxY - (rect.y + rect.height) * box.height,
            width: rect.width * box.width,
            height: rect.height * box.height
        )
        guard region.width > 2, region.height > 2 else { return nil }
        let scale = min(maximumScale, cropPixelWidth / region.width)
        let size = CGSize(width: (region.width * scale).rounded(), height: (region.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            // PDF space is bottom-up; flip, then move the region to the origin.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            page.drawMediaBox(region, to: cg)
        }
    }
}

/// A figure, or one of its panels, cut from the source's PDF page: the
/// region the Mac's figure analysis measured, or the whole page when it has
/// none. The chat's figure card and the walkthrough deck both draw it.
struct MobilePaperFigureImage: View {
    let figure: SyncedPaperFigure
    var panel: PaperFigurePanel?
    /// The panel to cut out when the analysis measured none: found on the
    /// page from the letter the figure prints.
    var panelLabel: String?
    var sharesPageWithOtherFigures = false
    var relativePDFPath: String?
    /// Handed the rendered image, so a caller can show it larger.
    var onLoad: ((UIImage) -> Void)?

    private enum LoadState {
        case loading
        case loaded(UIImage)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 150)
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        "\(PaperWalkthroughValidation.figurePanelLabel(figure.figureLabel, panel: panelLabel ?? panel?.label)) from page \(figure.pageNumber)"
                    )
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: "\(figure.id):\(panel?.id ?? panelLabel ?? "figure")") {
            state = .loading
            do {
                let image = try await MobilePaperFigureRenderer.shared.image(
                    for: figure,
                    panel: panel,
                    panelLabel: panelLabel,
                    sharesPageWithOtherFigures: sharesPageWithOtherFigures,
                    relativePDFPath: relativePDFPath
                )
                state = .loaded(image)
                onLoad?(image)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct MobilePaperFigureCard: View {
    let figure: SyncedPaperFigure
    var panel: PaperFigurePanel?
    var relativePDFPath: String?

    init(figure: SyncedPaperFigure, panel: PaperFigurePanel? = nil, relativePDFPath: String? = nil) {
        self.figure = figure
        self.panel = panel
        self.relativePDFPath = relativePDFPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            MobilePaperFigureImage(figure: figure, panel: panel, relativePDFPath: relativePDFPath)

            HStack(alignment: .firstTextBaseline) {
                Text(PaperWalkthroughValidation.figurePanelLabel(figure.figureLabel, panel: panel?.label))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Page \(figure.pageNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let explanation = panel?.explanation ?? figure.analysis?.summary,
               !explanation.isEmpty {
                Text(explanation)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
        .padding(MobileDesign.Spacing.medium)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
