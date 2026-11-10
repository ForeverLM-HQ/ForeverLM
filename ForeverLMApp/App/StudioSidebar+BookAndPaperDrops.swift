// The source sidebar's meeting import buttons and book and paper file drops.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
    func startGoogleDriveMeetingImport() {
        // While Google's page is open the same button stops waiting for it.
        guard !isGoogleDriveWorking else {
            Task { await GoogleDriveService.shared.cancelPendingConnection() }
            return
        }
        isGoogleDriveWorking = true
        Task {
            defer { isGoogleDriveWorking = false }
            do {
                try await vm.connectAndImportGoogleDriveMeetings(
                    reconnectOnly: isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                )
            } catch GoogleDriveServiceError.noFolderSelected {
                // Closing Google's picker is a normal cancellation.
            } catch is CancellationError {
                // The sidebar or app closed while the browser flow was open.
            } catch {
                vm.errorMessage = error.localizedDescription
                vm.showToast(error.localizedDescription)
            }
        }
    }

    func handleBookFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard sidebar.sidebarTab == .books else { return false }
        isAddBookButtonDropTargeted = false
        isBooksDropTargeted = false
        let candidates = providers.compactMap { provider -> (NSItemProvider, BookDropRepresentation)? in
            guard let representation = bookDropRepresentation(for: provider) else { return nil }
            return (provider, representation)
        }
        guard !candidates.isEmpty else {
            presentBookDropError("Drop a PDF, EPUB, or DRM-free Kindle book.")
            return true
        }
        if vm.bookImportsPending == 0 {
            vm.bookImportStatus = candidates.count == 1 ? "Opening dropped book…" : "Opening dropped books…"
        }
        for (provider, representation) in candidates {
            switch representation {
            case .fileURL:
                loadDroppedBookURL(from: provider)
            case .content(let typeIdentifier):
                loadDroppedBookFileRepresentation(from: provider, typeIdentifier: typeIdentifier)
            }
        }
        return true
    }

    /// The line under Add Book: what the running import is doing, and how
    /// many more books wait behind it.
    var bookImportProgressLine: String {
        let status = vm.bookImportStatus.isEmpty ? "Waiting to import…" : vm.bookImportStatus
        let waiting = vm.bookImportsPending - 1
        guard waiting > 0 else { return status }
        return "\(status)\n\(waiting) more \(waiting == 1 ? "book" : "books") waiting"
    }

    /// Imports each picked book in turn, saying at the end which ones failed.
    func importBooks(_ urls: [URL]) async {
        let runs = urls.map { ($0, vm.enqueueBookImport(from: $0.path)) }
        var failures: [String] = []
        for (url, run) in runs {
            do {
                try await run.value
            } catch {
                failures.append(urls.count == 1
                    ? error.localizedDescription
                    : "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !failures.isEmpty else { return }
        vm.errorMessage = failures.joined(separator: "\n")
        vm.showBookImportError = true
    }

    private enum BookDropRepresentation {
        case fileURL
        case content(String)
    }

    private func bookDropRepresentation(for provider: NSItemProvider) -> BookDropRepresentation? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return .fileURL
        }
        guard let typeIdentifier = supportedBookImportContentTypes
            .map(\.identifier)
            .first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return nil }
        return .content(typeIdentifier)
    }

    private func loadDroppedBookURL(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
            if let url = droppedFileURL(from: item) {
                importDroppedBook(at: url)
                return
            }

            if let typeIdentifier = supportedBookImportContentTypes
                .map(\.identifier)
                .first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                loadDroppedBookFileRepresentation(
                    from: provider,
                    typeIdentifier: typeIdentifier,
                    priorErrorDescription: error?.localizedDescription
                )
                return
            }

            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
            Task { @MainActor in
                presentBookDropError("ForeverLM couldn’t read the dropped book from Finder\(detail).")
            }
        }
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let nsURL = item as? NSURL {
            url = nsURL as URL
        } else if let candidate = item as? URL {
            url = candidate
        } else if let value = item as? String {
            let parsed = URL(string: value)
            url = parsed?.isFileURL == true ? parsed : URL(fileURLWithPath: value)
        } else {
            url = nil
        }
        guard let url, url.isFileURL else { return nil }
        return url
    }

    /// Some Finder drops vend only their concrete content type (for example
    /// `org.idpf.epub-container`) and no `public.file-url`. The provider-owned
    /// URL disappears when this callback returns, so stage it before starting
    /// the asynchronous importer.
    private func loadDroppedBookFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        priorErrorDescription: String? = nil
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
            guard let temporaryURL else {
                let cause = error?.localizedDescription ?? priorErrorDescription
                let detail = cause.map { ": \($0)" } ?? ""
                Task { @MainActor in
                    presentBookDropError("ForeverLM couldn’t open the dropped book\(detail).")
                }
                return
            }

            do {
                let sourceExtension = temporaryURL.pathExtension.lowercased()
                let preferredExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? ""
                let fileExtension = sourceExtension.isEmpty ? preferredExtension : sourceExtension
                // The book's folder and its stored copy are named after the
                // file, so the staged copy keeps the dropped file's own name,
                // in a folder of its own. A UUID for a name gave the book a
                // folder called "ForeverLM-Dropped-Book-…".
                let stagingDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ForeverLM-Dropped-Book-\(UUID().uuidString)", isDirectory: true)
                let droppedName = temporaryURL.deletingPathExtension().lastPathComponent
                var stagedURL = stagingDirectory
                    .appendingPathComponent(droppedName.isEmpty ? "Book" : droppedName)
                if !fileExtension.isEmpty {
                    stagedURL.appendPathExtension(fileExtension)
                }
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
                importDroppedBook(at: stagedURL, removeAfterImport: true, stagingDirectory: stagingDirectory)
            } catch {
                Task { @MainActor in
                    presentBookDropError("ForeverLM couldn’t copy the dropped book: \(error.localizedDescription)")
                }
            }
        }
    }

    private func importDroppedBook(at url: URL, removeAfterImport: Bool = false, stagingDirectory: URL? = nil) {
        Task { @MainActor in
            defer {
                if removeAfterImport {
                    let staged = stagingDirectory ?? url
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: staged)
                    }
                }
            }
            do {
                try await vm.importBook(from: url.path)
            } catch {
                presentBookDropError("Couldn’t import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func presentBookDropError(_ message: String) {
        // A book still importing keeps its progress line.
        if vm.bookImportsPending == 0 { vm.bookImportStatus = "" }
        vm.errorMessage = message
        vm.showBookImportError = true
    }

    /// Drops onto empty space in the Papers tab or onto the "Upload PDFs…"
    /// button import each dropped PDF as a new paper source — a "dropbox" for
    /// freshly downloaded papers. Drops onto an existing paper row are handled
    /// by ArticleRow's own onDrop (attach to that paywalled paper) and never
    /// reach here.
    func handlePaperFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard sidebar.sidebarTab == .papers else { return false }
        return PaperFileDrop.load(
            providers,
            deliver: { url, displayName, staged in
                PaperIngestionDiagnostics.recordDropAccepted(filename: displayName)
                importDroppedPaperPDF(at: url, displayName: displayName, stagedFile: staged)
            },
            fail: { filename, message in
                presentPaperDropError(filename: filename, message: message)
            }
        )
    }

    private func importDroppedPaperPDF(
        at url: URL,
        displayName: String,
        stagedFile: PaperDropStager.StagedFile? = nil
    ) {
        Task { @MainActor in
            defer {
                if let stagedFile {
                    PaperDropStager.cleanup(stagedFile)
                }
            }
            do {
                let sourceID = try await vm.importPDF(
                    from: url.path,
                    selectInReader: false
                )
                PaperIngestionDiagnostics.recordDropImported(
                    filename: displayName,
                    sourceID: sourceID
                )
                // Name the paper, not the file: a drop that arrived without a
                // filename would otherwise announce "Imported Dropped Paper.pdf".
                let importedTitle = vm.articles.first(where: { $0.id == sourceID })?.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                vm.showToast("Imported \(importedTitle?.isEmpty == false ? importedTitle! : displayName)")
            } catch {
                presentPaperDropError(filename: displayName, error: error)
            }
        }
    }

    private func presentPaperDropError(filename: String?, error: Error) {
        presentPaperDropError(filename: filename, message: error.localizedDescription)
    }

    private func presentPaperDropError(filename: String?, message: String) {
        let displayName = PaperDropStager.safePDFFilename(filename)
        PaperIngestionDiagnostics.recordDropFailure(filename: displayName, message: message)
        Task { @MainActor in
            vm.showToast("Couldn’t import \(displayName): \(message)")
        }
    }
}
