import CryptoKit
import Foundation
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {
    private static let notebookDirectoryName = "Projects"
    static let notebookMarkdownFileByteLimit = 2 * 1_024 * 1_024
    static let notebookMaterialContextCharacterLimit = 200_000
    private var notebookFileManager: FileManager { FileManager.default }

    func notebookWorkspaceURL(notebookID: String, createIfNeeded: Bool = true) throws -> URL {
        guard !notebookID.isEmpty,
              !notebookID.contains("/"),
              !notebookID.contains("..") else {
            throw KnowledgeStoreError.invalidData("Invalid Notebook identifier.")
        }
        guard let notebook = try notebookFilesKnowledgeStore().loadLearningGoal(notebookID),
              notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        let root = libraryRootURL
            .appendingPathComponent(Self.notebookDirectoryName, isDirectory: true)
            .appendingPathComponent(notebookID, isDirectory: true)
        if createIfNeeded {
            try notebookFileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// Disposes of a deleted Notebook's workspace folder. The `notebook_files`
    /// rows are a rebuildable index of the folder, so dropping them alone would
    /// leave the actual documents behind, unreachable and still on disk.
    /// The Trash rather than an unlink: these are the learner's own files, and
    /// a deletion they can walk back is worth the Trash entry. A failure here
    /// is not fatal — the Notebook is already gone and a stray folder is inert.
    func discardNotebookWorkspace(at url: URL) {
        guard notebookFileManager.fileExists(atPath: url.path) else { return }
        #if os(macOS)
        do {
            try notebookFileManager.trashItem(at: url, resultingItemURL: nil)
            return
        } catch {
            // Falls through to an outright remove: a workspace on a volume with
            // no Trash still has to go, or the next Notebook reusing this id
            // inherits its files.
        }
        #endif
        try? notebookFileManager.removeItem(at: url)
    }

    /// Moves what a merged Notebook's workspace holds into the survivor's. A
    /// name both folders already use lands under "From <merged Notebook>" in
    /// the survivor, so nothing the learner wrote is overwritten. The merged
    /// folder is removed only once it is empty: anything that would not move
    /// stays where it was, findable, rather than in the Trash. Returns the
    /// number of entries moved. Shared with the MCP server, which reaches the
    /// same folders without a StorageService of its own.
    @discardableResult
    static func adoptNotebookWorkspace(from source: URL, into destination: URL, mergedNotebookTitle: String) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let trimmedTitle = mergedNotebookTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let overflowFolder = destination.appendingPathComponent(
            "From \(trimmedTitle.isEmpty ? "merged notebook" : trimmedTitle)",
            isDirectory: true
        )
        var moved = 0
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var target = destination.appendingPathComponent(entry.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.createDirectory(at: overflowFolder, withIntermediateDirectories: true)
                target = overflowFolder.appendingPathComponent(entry.lastPathComponent)
                var attempt = 2
                while fileManager.fileExists(atPath: target.path) {
                    let stem = entry.deletingPathExtension().lastPathComponent
                    let ext = entry.pathExtension
                    let name = ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
                    target = overflowFolder.appendingPathComponent(name)
                    attempt += 1
                }
            }
            if (try? fileManager.moveItem(at: entry, to: target)) != nil {
                moved += 1
            }
        }
        let remaining = (try? fileManager.contentsOfDirectory(atPath: source.path))?
            .filter { $0 != ".DS_Store" } ?? []
        if remaining.isEmpty {
            try? fileManager.removeItem(at: source)
        }
        return moved
    }

    func loadNotebookFiles(notebookID: String) throws -> [NotebookFileRecord] {
        try reconcileNotebookFiles(notebookID: notebookID)
    }

    /// Load a complete Markdown artifact with a content revision. This is
    /// intentionally separate from the bounded preview path: an editor must
    /// never save a truncated preview back over the learner's file.
    func notebookMarkdownFile(
        notebookID: String,
        relativePath rawRelativePath: String
    ) throws -> NotebookMarkdownFileSnapshot {
        let relativePath = try NotebookMarkdownFilePath.validatedRelativePath(rawRelativePath)
        let records = try reconcileNotebookFiles(notebookID: notebookID)
        guard let record = records.first(where: { $0.notebookRelativePath == relativePath }) else {
            throw NotebookMarkdownFileError.unavailable(relativePath)
        }
        return try notebookMarkdownFileSnapshot(for: record)
    }

    /// Create or revision-safely replace a Markdown artifact. Existing files
    /// require the SHA-256 returned by `notebookMarkdownFile`; callers that omit
    /// it may create a new file but can never overwrite one accidentally.
    @discardableResult
    func writeNotebookMarkdownFile(
        notebookID: String,
        relativePath rawRelativePath: String,
        markdown: String,
        expectedRevision: String?
    ) throws -> NotebookMarkdownFileSnapshot {
        let relativePath = try NotebookMarkdownFilePath.validatedRelativePath(rawRelativePath)
        let data = Data(markdown.utf8)
        guard data.count <= Self.notebookMarkdownFileByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(maxBytes: Self.notebookMarkdownFileByteLimit)
        }

        let store = try notebookFilesKnowledgeStore()
        guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        guard !notebook.isArchived else {
            throw KnowledgeStoreError.invalidData("Archived Notebooks are read-only.")
        }

        let records = try reconcileNotebookFiles(notebookID: notebookID)
        let existing = records.first(where: { $0.notebookRelativePath == relativePath })
        if let existing {
            let current = try notebookMarkdownFileSnapshot(for: existing)
            guard let expectedRevision,
                  current.revision.caseInsensitiveCompare(expectedRevision) == .orderedSame else {
                throw NotebookMarkdownFileError.conflict(relativePath)
            }
        } else if expectedRevision != nil {
            // A caller editing an existing revision must not recreate a file
            // that was deleted or moved while it was open.
            throw NotebookMarkdownFileError.conflict(relativePath)
        }

        let workspace = try notebookWorkspaceURL(notebookID: notebookID)
        let destination = workspace.appendingPathComponent(relativePath)
        try notebookFileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        notebookMaterialContextCache[notebookID] = nil

        let updatedRecords = try reconcileNotebookFiles(notebookID: notebookID)
        guard let updated = updatedRecords.first(where: { $0.notebookRelativePath == relativePath }) else {
            throw NotebookMarkdownFileError.unavailable(relativePath)
        }
        return try notebookMarkdownFileSnapshot(for: updated)
    }

    /// Create a learner-named Markdown artifact without replacing an existing
    /// file. Finder-style numeric suffixes keep this action non-destructive.
    func createNotebookMarkdownFile(
        notebookID: String,
        preferredRelativePath rawRelativePath: String
    ) throws -> NotebookMarkdownFileSnapshot {
        let relativePath = try NotebookMarkdownFilePath.validatedRelativePath(rawRelativePath)
        let workspace = try notebookWorkspaceURL(notebookID: notebookID)
        let requested = workspace.appendingPathComponent(relativePath)
        let parent = requested.deletingLastPathComponent()
        try notebookFileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = uniqueNotebookFileDestination(
            directory: parent,
            preferredName: requested.lastPathComponent
        )
        let parentRelativePath = relativePath.split(separator: "/").dropLast().joined(separator: "/")
        let uniqueRelativePath = parentRelativePath.isEmpty
            ? destination.lastPathComponent
            : "\(parentRelativePath)/\(destination.lastPathComponent)"
        return try writeNotebookMarkdownFile(
            notebookID: notebookID,
            relativePath: uniqueRelativePath,
            markdown: "",
            expectedRevision: nil
        )
    }

    /// Every workspace file is Notebook-native context. The user owns the folder
    /// structure and names. The inventory, the iCloud eviction check and the cache
    /// stay on this actor; the reading itself does not, because opening a file can
    /// block and a scanned PDF may require Vision OCR.
    func notebookMaterialContext(notebookID: String) async throws -> String {
        let records = try reconcileNotebookFiles(notebookID: notebookID)
        let artifacts = try loadArtifacts(notebookID: notebookID)
        let fileSignature = records.map {
            "\($0.id)|\($0.sizeBytes)|\($0.modifiedAt.timeIntervalSinceReferenceDate)"
        }.joined(separator: "\n")
        let artifactSignature = artifacts.map {
            "\($0.id)|\($0.updatedAt.timeIntervalSinceReferenceDate)"
        }.joined(separator: "\n")
        let signature = fileSignature + "\n--artifacts--\n" + artifactSignature
        if let cached = notebookMaterialContextCache[notebookID],
           cached.signature == signature {
            return cached.markdown
        }

        for record in records {
            let url = notebookFileURL(for: record)
            guard try prepareNotebookFileForReading(url) else {
                throw KnowledgeStoreError.invalidData(
                    "Notebook file “\(record.notebookRelativePath)” is downloading from iCloud. Try again when the download finishes."
                )
            }
        }

        // Rendering opens every PDF and may run per-page OCR: seconds of
        // synchronous work per file. Done inside this actor it held every other
        // storage call hostage, and a chat send queued behind it sat at "Getting
        // your sources ready" until the last page was read. The actor lets go for
        // the render; only the cache write comes back through it. A file written
        // meanwhile clears the cache, and the signature is recomputed from disk on
        // every call, so a stale entry stored here is never served.
        let rootURL = libraryRootURL
        let fileMarkdown = try await Task.detached(priority: .userInitiated) {
            try Self.renderNotebookMaterialContext(
                records: records,
                rootURL: rootURL,
                maxCharacters: Self.notebookMaterialContextCharacterLimit
            )
        }.value
        let artifactMarkdown = try notebookArtifactContext(notebookID: notebookID)
        let combinedMarkdown = [artifactMarkdown, fileMarkdown]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let markdown = String(combinedMarkdown.prefix(Self.notebookMaterialContextCharacterLimit))
        notebookMaterialContextCache[notebookID] = (signature, markdown)
        return markdown
    }

    /// Shared by the in-app Notebook chat and `get_notebook_context`, so both
    /// surfaces see the same authoritative Notebook files. Call only from
    /// an off-main executor: PDF extraction can perform synchronous I/O and OCR.
    nonisolated static func renderNotebookMaterialContext(
        records: [NotebookFileRecord],
        rootURL: URL,
        maxCharacters: Int
    ) throws -> String {
        guard !records.isEmpty else { return "" }

        let contextLimit = max(1_000, min(maxCharacters, notebookMaterialContextCharacterLimit))
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "py", "r", "jl", "swift", "js", "ts",
            "json", "yaml", "yml", "toml", "sql", "sh", "zsh", "bash", "xml",
            "html", "css", "log", "csv", "tsv", "ipynb",
        ]
        let orderedRecords = records.sorted {
            $0.notebookRelativePath.localizedStandardCompare($1.notebookRelativePath) == .orderedAscending
        }
        let inventory = orderedRecords.map { record in
            "- \(record.notebookRelativePath) (\(record.sizeDescription))"
        }.joined(separator: "\n")
        var remaining = max(0, contextLimit - inventory.count)
        var blocks = ["### File inventory\n\n\(inventory)"]
        var renderedContentCount = 0

        for record in orderedRecords {
            guard remaining > 0 else { break }
            let url = rootURL.appendingPathComponent(record.relativePath)
            let displayPath = record.notebookRelativePath
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KnowledgeStoreError.invalidData(
                    "Notebook file “\(displayPath)” is unavailable on this device."
                )
            }

            let content: String
            switch record.pathExtension {
            case "pdf":
                #if canImport(PDFKit)
                guard let document = PDFDocument(url: url) else {
                    throw KnowledgeStoreError.invalidData(
                        "Notebook file “\(displayPath)” could not be opened as a PDF."
                    )
                }
                let extracted = PDFTextExtractor.text(
                    from: document,
                    pages: 0..<document.pageCount
                )
                content = String(extracted.prefix(remaining))
                #else
                throw KnowledgeStoreError.invalidData(
                    "PDF Notebook files are unavailable on this platform."
                )
                #endif
            case _ where textExtensions.contains(record.pathExtension):
                content = try boundedNotebookMaterialText(at: url, maxCharacters: remaining)
            default:
                blocks.append(
                    "### \(displayPath)\n\n[This Notebook file format cannot be read into assistant context.]"
                )
                renderedContentCount += 1
                continue
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw KnowledgeStoreError.invalidData(
                    "Notebook file “\(displayPath)” contains no readable text."
                )
            }
            blocks.append("### \(displayPath)\n\n\(trimmed)")
            renderedContentCount += 1
            remaining -= trimmed.count
        }

        if remaining == 0, renderedContentCount < orderedRecords.count {
            blocks.append("[Additional Notebook file contents omitted because context reached its character limit.]")
        }
        return """
        ## Notebook files

        \(blocks.joined(separator: "\n\n"))
        """
    }

    private nonisolated static func boundedNotebookMaterialText(
        at url: URL,
        maxCharacters: Int
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxCharacters + 1) ?? Data()
        return String(decoding: data.prefix(maxCharacters), as: UTF8.self)
    }

    @discardableResult
    func importNotebookFiles(
        notebookID: String,
        urls: [URL]
    ) throws -> [NotebookFileRecord] {
        let workspace = try notebookWorkspaceURL(notebookID: notebookID)

        for sourceURL in urls {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let resourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard resourceValues.isRegularFile == true || resourceValues.isDirectory == true else {
                throw KnowledgeStoreError.invalidData("The selected item is not a file or folder.")
            }

            let destination = uniqueNotebookFileDestination(
                directory: workspace,
                preferredName: sourceURL.lastPathComponent
            )
            try notebookFileManager.copyItem(at: sourceURL, to: destination)
        }
        return try reconcileNotebookFiles(notebookID: notebookID)
    }

    func notebookFileURL(for record: NotebookFileRecord) -> URL {
        libraryRootURL.appendingPathComponent(record.relativePath)
    }

    private func notebookMarkdownFileSnapshot(
        for record: NotebookFileRecord
    ) throws -> NotebookMarkdownFileSnapshot {
        guard record.isMarkdownDocument else {
            throw NotebookMarkdownFileError.unsupportedExtension
        }
        let url = notebookFileURL(for: record)
        guard try prepareNotebookFileForReading(url) else {
            throw NotebookMarkdownFileError.unavailable(record.notebookRelativePath)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.notebookMarkdownFileByteLimit + 1) ?? Data()
        guard data.count <= Self.notebookMarkdownFileByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(maxBytes: Self.notebookMarkdownFileByteLimit)
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw KnowledgeStoreError.invalidData(
                "Notebook file “\(record.notebookRelativePath)” is not valid UTF-8 text."
            )
        }
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return NotebookMarkdownFileSnapshot(record: record, markdown: markdown, revision: revision)
    }

    private func reconcileNotebookFiles(notebookID: String) throws -> [NotebookFileRecord] {
        let workspace = try notebookWorkspaceURL(notebookID: notebookID)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = notebookFileManager.enumerator(
            at: workspace,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            let store = try notebookFilesKnowledgeStore()
            let stored = try store.loadNotebookFiles(notebookID: notebookID)
            if !stored.isEmpty {
                try store.replaceNotebookFiles(notebookID: notebookID, with: [])
            }
            return []
        }

        var recordsByPath: [String: NotebookFileRecord] = [:]
        for case let enumeratedURL as URL in enumerator {
            let values = try? enumeratedURL.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, enumeratedURL.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let fileName = logicalNotebookFileName(for: enumeratedURL.lastPathComponent)
            guard fileName != ".DS_Store", !fileName.isEmpty else { continue }
            let logicalURL = enumeratedURL
                .deletingLastPathComponent()
                .appendingPathComponent(fileName)
            let relativePath = relativeNotebookFilePath(for: logicalURL)
            let modifiedAt = values?.contentModificationDate ?? Date.distantPast
            let createdAt = values?.creationDate ?? modifiedAt
            let record = NotebookFileRecord(
                id: stableNotebookFileID(notebookID: notebookID, relativePath: relativePath),
                notebookID: notebookID,
                relativePath: relativePath,
                name: fileName,
                contentType: UTType(filenameExtension: logicalURL.pathExtension)?.identifier,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modifiedAt: modifiedAt,
                createdAt: createdAt
            )
            recordsByPath[relativePath] = record
        }

        let records = recordsByPath.values.sorted {
            $0.notebookRelativePath.localizedStandardCompare($1.notebookRelativePath) == .orderedAscending
        }
        let store = try notebookFilesKnowledgeStore()
        let storedByID = Dictionary(
            uniqueKeysWithValues: try store.loadNotebookFiles(notebookID: notebookID).map { ($0.id, $0) }
        )
        let reconciledByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        if storedByID != reconciledByID {
            try store.replaceNotebookFiles(notebookID: notebookID, with: records)
        }
        return records
    }

    private func relativeNotebookFilePath(for url: URL) -> String {
        let rootPath = libraryRootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func logicalNotebookFileName(for name: String) -> String {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else {
            return name
        }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private func stableNotebookFileID(notebookID: String, relativePath: String) -> String {
        NotebookFileArtifact.localID(notebookID: notebookID, relativePath: relativePath)
    }

    private func uniqueNotebookFileDestination(directory: URL, preferredName: String) -> URL {
        let safeName = preferredName.isEmpty ? "Untitled" : preferredName
        let candidate = directory.appendingPathComponent(safeName)
        guard !notebookFileDestinationExists(candidate) else {
            let source = URL(fileURLWithPath: safeName)
            let base = source.deletingPathExtension().lastPathComponent
            let pathExtension = source.pathExtension
            var suffix = 2
            while true {
                let name = pathExtension.isEmpty
                    ? "\(base) \(suffix)"
                    : "\(base) \(suffix).\(pathExtension)"
                let next = directory.appendingPathComponent(name)
                if !notebookFileDestinationExists(next) {
                    return next
                }
                suffix += 1
            }
        }
        return candidate
    }

    private func notebookFileDestinationExists(_ url: URL) -> Bool {
        if notebookFileManager.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return notebookFileManager.fileExists(atPath: placeholder.path)
    }

    private func prepareNotebookFileForReading(_ url: URL) throws -> Bool {
        if notebookFileManager.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
            )
            if values?.isUbiquitousItem == true,
               values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try notebookFileManager.startDownloadingUbiquitousItem(at: url)
                return false
            }
            return true
        }

        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard notebookFileManager.fileExists(atPath: placeholder.path) else { return false }
        try notebookFileManager.startDownloadingUbiquitousItem(at: placeholder)
        return false
    }
}
