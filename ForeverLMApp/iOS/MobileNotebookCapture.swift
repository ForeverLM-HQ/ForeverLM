import PhotosUI
import SwiftUI
import UIKit
import VisionKit

// Pages into a notebook from the phone (docs/notebooks-design.md, "iPhone"):
// the document camera, Photos, and the step that files a PDF into the
// library and a notebook, which Add sources and the Sources tab's Scan Pages
// share.

// MARK: - Filing into a notebook

/// Why a PDF or pages did not reach the notebook, in words for the learner.
struct MobileNotebookFilingFailure: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

extension MobileAudioReviewViewModel {
    /// A PDF on this phone into the library and a notebook, filed in the
    /// capture itself (`captureFile`, D47).
    func fileIntoNotebook(
        pdfAt url: URL,
        title: String?,
        notebook: MobileCloudNotebook,
        capture: String = "pdf"
    ) async -> Result<MobileCloudSource, MobileNotebookFilingFailure> {
        // Its pdf satellites uploaded first, then a Job with the notebook as its target before the first
        // complete Catalog pass, or the Source and its Entry after it. Before the pass the library shows it
        // once a Mac has added it.
        guard let id = await captureFile(url: url, title: title, capture: capture, target: MobileCaptureTarget(notebookID: notebook.id)) else {
            return .failure(MobileNotebookFilingFailure(message: errorMessage ?? "The PDF could not be added."))
        }
        let source = allSources.first { $0.id == id } ?? MobileCloudSource(
            id: id, title: title ?? url.deletingPathExtension().lastPathComponent, subtitle: nil, sourceType: "paper",
            dateAdded: Date(), hasAudio: false, isArchived: false
        )
        return .success(source)
    }

    /// Pages scanned or picked, made into one PDF that carries the words
    /// read on them (`MobileScannedPagesPDF`), filed under `title` into the
    /// library and the notebook. The PDF is made off the main actor and
    /// written to a temporary file, which goes once it is filed.
    func filePages(
        _ pictures: [MobileScannedPagesPDF.Picture],
        title: String,
        notebook: MobileCloudNotebook,
        capture: String = "scan"
    ) async -> Result<MobileCloudSource, MobileNotebookFilingFailure> {
        let fileName = MobileCapturedPages.fileName(forTitle: title)
        let written: URL? = await Task.detached(priority: .userInitiated) {
            guard let data = MobileScannedPagesPDF.pdf(from: pictures) else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(fileName, isDirectory: false)
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        }.value
        guard let written else {
            return .failure(MobileNotebookFilingFailure(message: "The pages could not be made into a PDF."))
        }
        let filed = await fileIntoNotebook(pdfAt: written, title: title, notebook: notebook, capture: capture)
        let directory = written.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
        return filed
    }
}

/// Photos picked in order, read as files for `MobileScannedPagesPDF`. Nil
/// when one cannot be read: the PDF would be filed short of a page.
enum MobilePickedPhotos {
    static func pictures(_ items: [PhotosPickerItem]) async -> [MobileScannedPagesPDF.Picture]? {
        var pictures: [MobileScannedPagesPDF.Picture] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
            pictures.append(.encoded(data))
        }
        return pictures
    }
}

// MARK: - The document camera

/// VisionKit's document camera, which finds a page's edges, flattens it
/// and takes as many pages as the learner scans. `onFinish` hears the pages
/// in order, none when the learner cancels, or the camera's error.
struct MobileDocumentScanner: UIViewControllerRepresentable {
    let onFinish: (Result<[MobileScannedPagesPDF.Picture], Error>) -> Void

    /// False on a device with no camera the scanner can use, and in the
    /// Simulator.
    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: (Result<[MobileScannedPagesPDF.Picture], Error>) -> Void

        init(onFinish: @escaping (Result<[MobileScannedPagesPDF.Picture], Error>) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pictures = (0..<scan.pageCount).compactMap { index in
                Self.picture(scan.imageOfPage(at: index))
            }
            // A page that cannot be read leaves nothing rather than a PDF
            // short of it.
            guard pictures.count == scan.pageCount else {
                onFinish(.failure(MobileNotebookFilingFailure(message: "A scanned page could not be read.")))
                return
            }
            onFinish(.success(pictures))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(.success([]))
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onFinish(.failure(error))
        }

        /// The camera's pages come upright; anything else is drawn upright
        /// by its JPEG's orientation when the PDF is made.
        private static func picture(_ image: UIImage) -> MobileScannedPagesPDF.Picture? {
            if image.imageOrientation == .up, let cgImage = image.cgImage {
                return .image(cgImage)
            }
            return image.jpegData(compressionQuality: 0.9).map { .encoded($0) }
        }
    }
}

// MARK: - A way in

/// One way into a notebook in Add sources, as the Mac draws a Studio tile
/// (`NotebookStudioTileLabel`'s chip): its glyph beside its word, in a quiet
/// rounded field with a hairline.
struct MobileAddSourcesTile: View {
    let title: String
    let systemImage: String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
    }
}
