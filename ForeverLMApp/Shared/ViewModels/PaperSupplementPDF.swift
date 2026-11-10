// A journal supplement joined to its paper in one PDF.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
import Darwin

// MARK: - Supplementary material

/// A journal's supplementary file, joined to its paper: the supplement's pages
/// follow the article's own, in one PDF.
///
/// ForeverLM keeps one PDF per paper, and most journals ship supplementary
/// figures (and some ship Extended Data) as a separate file. A paper whose text
/// names "Supplementary Fig. 3" could not show it: 403 of the library's 474
/// papers that mention supplementary figures did not carry them (survey,
/// 2026-11-08). Appending the file is what Nature already does with Extended
/// Data, so everything that reads a paper's PDF — the figure index, the Reader,
/// search, chat — reads the supplement with no change of its own (product
/// owner, 2026-11-08: "it should be able to attach those at the end of the
/// current pdf or something").
///
/// The joined PDF is written to a new file beside the paper's, never over it.
/// Everything that keeps derived data for a paper notices a new path — the
/// figure index (`paperFigureIndexIsCurrent`), the search index
/// (`sourcesMissingIndex`) and the synced file, which another device fetches
/// only for a path it does not hold. The article's pages keep their numbers,
/// so highlights, reading positions and figure ids stay where they were. No
/// model reads the paper again: its metadata is the article's. Once the paper
/// points at the joined file, the file it replaced is removed unless another
/// source keeps it (`removeReplacedFile`).
enum PaperSupplementPDF {
    struct Outcome: Equatable, Sendable {
        /// The joined PDF, absolute.
        let path: String
        let articlePageCount: Int
        let addedPageCount: Int
    }

    enum Failure: LocalizedError, Equatable {
        case unreadablePaper
        case unreadableSupplement
        case emptySupplement
        /// The supplement's first page is already one of the paper's pages:
        /// it was attached before, or it is the article itself.
        case alreadyAttached
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadablePaper: "The paper's own PDF could not be read."
            case .unreadableSupplement: "The supplementary file is not a readable PDF."
            case .emptySupplement: "The supplementary PDF has no pages."
            case .alreadyAttached: "This PDF is already part of the paper: its first page is one of the paper's pages."
            case .writeFailed: "The joined PDF could not be written."
            }
        }
    }

    /// The suffix a joined PDF's file name carries, before any counter.
    static let fileSuffix = "-with-supplement"

    /// Join `supplementPath`'s pages after `paperPath`'s into a new file beside
    /// the paper's, and return it. The paper's file is left as it was.
    static func append(supplementAt supplementPath: String, toPaperAt paperPath: String) throws -> Outcome {
        guard let paper = PDFDocument(url: URL(fileURLWithPath: paperPath)), paper.pageCount > 0 else {
            throw Failure.unreadablePaper
        }
        guard let supplement = PDFDocument(url: URL(fileURLWithPath: supplementPath)) else {
            throw Failure.unreadableSupplement
        }
        guard supplement.pageCount > 0 else { throw Failure.emptySupplement }
        if holdsPage(paper, matching: supplement) { throw Failure.alreadyAttached }

        let articlePageCount = paper.pageCount
        for index in 0..<supplement.pageCount {
            guard let page = supplement.page(at: index)?.copy() as? PDFPage else { throw Failure.unreadableSupplement }
            paper.insert(page, at: paper.pageCount)
        }
        let fm = FileManager.default
        let destination = destinationPath(for: paperPath) { fm.fileExists(atPath: $0) }
        let destinationURL = URL(fileURLWithPath: destination)
        let staged = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).incoming-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        guard paper.write(to: staged),
              let written = PDFDocument(url: staged),
              written.pageCount == articlePageCount + supplement.pageCount else {
            throw Failure.writeFailed
        }
        do {
            try fm.moveItem(at: staged, to: destinationURL)
        } catch {
            throw Failure.writeFailed
        }
        return Outcome(path: destination, articlePageCount: articlePageCount, addedPageCount: supplement.pageCount)
    }

    /// Remove the paper's file the joined PDF replaced, once the paper points
    /// at the joined one. Only a file in the Papers folder that no other
    /// source keeps is removed: the copy on another device is that device's,
    /// and a file two rows share stays for the other. Returns whether it was
    /// removed.
    @discardableResult
    static func removeReplacedFile(storedPath: String, usedElsewhere: Bool) -> Bool {
        guard !usedElsewhere, StorageService.relativeSourcePath(storedPath).hasPrefix("Papers/") else { return false }
        return (try? FileManager.default.removeItem(atPath: StorageService.absoluteSourcePath(storedPath))) != nil
    }

    /// Where the joined PDF goes: beside the paper's file, named for it with
    /// `fileSuffix`, and a counter when a second supplement joins a paper that
    /// already has one ("x.pdf" → "x-with-supplement.pdf" →
    /// "x-with-supplement-2.pdf").
    static func destinationPath(for paperPath: String, fileExists: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: paperPath)
        let folder = url.deletingLastPathComponent()
        var base = url.deletingPathExtension().lastPathComponent
        if let range = base.range(of: #"-with-supplement(-\d+)?$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        var counter = 1
        while true {
            let name = base + fileSuffix + (counter == 1 ? "" : "-\(counter)") + ".pdf"
            let candidate = folder.appendingPathComponent(name).path
            if candidate != paperPath, !fileExists(candidate) { return candidate }
            counter += 1
        }
    }

    /// Whether `paper` already holds `supplement`'s first page, by its text.
    /// A page with too little text to tell (a scan, a cover with a logo) never
    /// matches, so such a supplement is attached rather than refused.
    static func holdsPage(_ paper: PDFDocument, matching supplement: PDFDocument) -> Bool {
        guard let first = supplement.page(at: 0).map({ normalizedPageText($0.string) }), first.count >= 80 else {
            return false
        }
        for index in 0..<paper.pageCount where normalizedPageText(paper.page(at: index)?.string) == first {
            return true
        }
        return false
    }

    static func normalizedPageText(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
