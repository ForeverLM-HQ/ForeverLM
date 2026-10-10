import Foundation
import PDFKit
import Testing
@testable import ForeverLM

/// A hand-run harness, not a regression test: it drives the real `show_source_image`
/// chain over a paper in the operator's own library and writes what the chat
/// transcript would display. Skips silently anywhere that PDF is not present.
@Suite("Paper Figure Demo Harness", .disabled(if: ProcessInfo.processInfo.environment["FIGURE_DEMO_OUT"] == nil))
struct PaperFigureDemoHarness {

    @Test("show_source_image returns a cropped figure for a paper nobody has explained")
    func realPaperEndToEnd() throws {
        let outDir = try #require(ProcessInfo.processInfo.environment["FIGURE_DEMO_OUT"])
        let pdf = try #require(ProcessInfo.processInfo.environment["FIGURE_DEMO_PDF"])
        try #require(FileManager.default.fileExists(atPath: pdf))
        let sourceID = "src_demo_sasp"

        // 1. What `prepareStructure` stores: captions and their pages. No model.
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: pdf)))
        let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
        let figures = indexed.map {
            PaperFigureRecord(
                id: PaperFigureIndexContract.figureID(
                    sourceID: sourceID, figureLabel: $0.figureLabel, pageIndex: $0.pageIndex
                ),
                sourceID: sourceID,
                figureLabel: $0.figureLabel,
                pageIndex: $0.pageIndex,
                caption: $0.caption,
                analysis: nil
            )
        }
        print("HARNESS indexed labels: \(figures.map(\.figureLabel).joined(separator: ", "))")
        #expect(!figures.isEmpty)
        #expect(figures.allSatisfy { $0.analysis == nil })

        // 2. What the tool lists for the model's query.
        let found = try SourceImageCatalog.entries(
            sourceID: sourceID, filePath: pdf, query: "Figure 3", page: nil
        )
        print("HARNESS listed: \(found.map(\.locationDescription).joined(separator: ", "))")

        // 3. The real crop glue.
        let entries = ReviewSessionManager.croppedToFigures(
            found, sourceID: sourceID, filePath: pdf, figures: figures, query: "Figure 3"
        )
        for e in entries {
            print("HARNESS entry: \(e.locationDescription) crop=\(e.reference.crop.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.x, $0.y, $0.width, $0.height) } ?? "none") — \(e.caption.prefix(60))")
        }
        let entry = try #require(entries.first)
        print("HARNESS markdown: \(entry.markdown)")
        let crop = try #require(entry.reference.crop, "the tool handed back an uncropped page")
        print(String(format: "HARNESS crop: x=%.3f y=%.3f w=%.3f h=%.3f", crop.x, crop.y, crop.width, crop.height))

        // 4. What the transcript renders, byte for byte.
        let rendered = try #require(SourceImageCatalog.render(entry.reference, filePath: pdf))
        let out = URL(fileURLWithPath: outDir).appendingPathComponent("transcript-figure.jpg")
        try rendered.data.write(to: out)
        print("HARNESS wrote \(out.path) (\(rendered.data.count) bytes, \(rendered.mediaType))")

        // And the page it used to send, for comparison.
        let whole = SourceImageReference(sourceID: sourceID, location: entry.reference.location)
        let wholeRendered = try #require(SourceImageCatalog.render(whole, filePath: pdf))
        try wholeRendered.data.write(
            to: URL(fileURLWithPath: outDir).appendingPathComponent("transcript-page.jpg")
        )
        #expect(rendered.data.count != wholeRendered.data.count)
    }
}
