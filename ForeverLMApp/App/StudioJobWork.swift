import Foundation

/// The Mac's own paths for the Jobs `MacJobRunner` runs (docs/cloudkit-schema-design.md §3.5.28, §5.4):
/// the Studio's link and file imports, the MCP tools in this process (`MCPToolRegistry`, so a tool's
/// checks and its cost confirmation apply), the scheduled-task runner's Run now, and the satellites in
/// the private `Content` zone through the coordinator's BlobStore. Generation 2 only: WP16 builds it with
/// the coordinator and attaches the runner (`MacJobRunner.attach(to:)`).
struct StudioJobWork: MacJobWork {
    let viewModel: StudioViewModel
    let storage: StorageService
    let coordinator: SyncCoordinator

    func importLink(_ url: String) async throws -> String? {
        let outcome = await viewModel.importLink(url, intoNotebook: nil)
        if case .failed(let message) = outcome.library { throw MacJobRunner.Failure(message: message) }
        return outcome.sourceID
    }

    func importFile(at file: URL, kind: JobFileKind, title: String?, asBook: Bool) async throws -> String? {
        switch kind {
        case .pdf where !asBook:
            return try await viewModel.importPDF(
                from: file.path, revealInLibrary: false, reportsExistingPaper: false, selectInReader: false
            )
        case .text:
            // A text source keeps its file where the library keeps its own, not in the Job's scratch folder.
            let kept = try await Task.detached(priority: .utility) { try Self.keepImportedFile(file) }.value
            try await viewModel.importTextFile(from: kept.path)
            return nil
        case .pdf, .epub:
            try await viewModel.importBook(from: file.path)
            return nil
        }
    }

    /// Copies a file a Job brought into `Imports/` in the library's folder, numbered beside a namesake.
    private static func keepImportedFile(_ file: URL) throws -> URL {
        let folder = URL(fileURLWithPath: StorageService.libraryRootPath).appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = file.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(file.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(counter).\(file.pathExtension)")
            counter += 1
        }
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    func fetchContent(sourceID: String) async throws {
        let answer = await callTool("refetch_source_content", arguments: ["source_id": .string(sourceID)])
        if answer.isError { throw MacJobRunner.Failure(message: answer.text) }
    }

    func attachFile(at file: URL, kind: JobFileKind, toSource sourceID: String) async throws {
        guard kind == .pdf else {
            // An EPUB or a text file a client already made a source for is imported as the Mac imports one.
            _ = try await importFile(at: file, kind: kind, title: nil, asBook: kind == .epub)
            return
        }
        let answer = await callTool("attach_pdf_to_paper", arguments: ["source_id": .string(sourceID), "file_path": .string(file.path)])
        if answer.isError { throw MacJobRunner.Failure(message: answer.text) }
    }

    func callTool(_ name: String, arguments: [String: SyncJSON]) async -> (text: String, isError: Bool) {
        let object = (try? JSONSerialization.jsonObject(with: SyncJSON.object(arguments).serialized())) as? [String: Any] ?? [:]
        let outcome = await MCPToolRegistry.shared.callToolDetailed(name: name, arguments: object)
        return (outcome.text, outcome.isError)
    }

    func bytes(of file: FileRef) async throws -> Data {
        guard let library = try await coordinator.store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: $0) }) else {
            throw MacJobRunner.Failure(message: "This Mac does not hold the library's root yet.")
        }
        return try await coordinator.blobs.fetch(file, from: .personal(salt: library.salt))
    }

    func runAutomation(_ id: String) async throws {
        try await storage.requestScheduledTaskRunNow(id)
        await MainActor.run { NotificationCenter.default.post(name: .scheduledTasksDidChange, object: nil) }
    }

    func moveIntoSpace(jobID: String, notebookID: String, params: [String: SyncJSON]) async throws -> String {
        try await SpaceMoveJob(coordinator: coordinator).runRequest(jobID: jobID, notebookID: notebookID, params: params)
    }

    func drawNotebookCover(notebookID: String) async throws -> String {
        guard let covers = NotebookCoverService.current else {
            throw MacJobRunner.Failure(message: "This Mac is not drawing notebook covers yet.")
        }
        switch try await covers.drawForJob(notebookID) {
        case .drawn: return "Drew the notebook's cover."
        case .hasCover: return "The notebook has a cover already."
        case .notActive: return "The notebook is archived, so it needs no cover."
        case .notHeld: throw MacJobRunner.Failure(message: "The notebook is gone.")
        }
    }

    func libraryDidChange() async {
        await MainActor.run { NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil) }
    }
}
