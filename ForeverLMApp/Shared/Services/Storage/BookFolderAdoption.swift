import Foundation

/// The on-disk half of dropping the archive tag from book folder names.
///
/// Six books imported from Anna's Archive kept the archive's whole download
/// name as their folder under `Books/`, as the name of the managed copy of the
/// original file inside it, and therefore in every chapter URL and cover path.
/// `BookFolderNaming` now strips that tag at import; this moves the folders
/// that already exist, and `KnowledgeStore.rewriteBookFolderReferences` moves
/// the rows that point at them. `StorageService.adoptTaggedBookFolders()` runs
/// the two halves together, once.
///
/// Everything here is idempotent and per-folder. A folder whose clean name is
/// already taken is left exactly where it is and reported, because two
/// editions of one title reduce to the same name and neither may overwrite
/// the other. A run that dies between the folder rename and the row rewrite is
/// finished by the next run: the rows still name the tagged folder, the disk
/// no longer has it, and the store's enumeration finds the gap.
enum BookFolderAdoption {

    struct Rename: Equatable, Hashable, Sendable {
        let oldName: String
        let newName: String
    }

    struct Report: Equatable, Sendable {
        /// Folders moved to their clean name on this run.
        var renamed: [Rename] = []
        /// Tagged folders left in place because the clean name already exists.
        var skippedBecauseDestinationExists: [String] = []
        /// Folders whose rename threw; the next run tries again.
        var failed: [String] = []
        /// Chapter sources whose stored paths were rewritten.
        var rewrittenChapterCount = 0
        /// Folder names the rows still point at after this run, on disk under
        /// neither their tagged nor their clean name, so nothing could be done.
        var unresolvedReferences: [String] = []

        /// True when nothing tagged remains on disk or in the rows, so the
        /// one-time run can retire itself.
        var isComplete: Bool {
            skippedBecauseDestinationExists.isEmpty && failed.isEmpty && unresolvedReferences.isEmpty
        }

        var didChangeAnything: Bool {
            !renamed.isEmpty || rewrittenChapterCount > 0
        }
    }

    /// Tagged folders directly under `booksDirectory`, paired with the names
    /// they should carry. Nothing recurses; chapter files inside a book keep
    /// whatever names the importer gave them.
    static func plannedRenames(in booksDirectory: URL, fileManager: FileManager = .default) -> [Rename] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: booksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> Rename? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            guard BookFolderNaming.isArchiveTaggedName(name) else { return nil }
            let cleaned = BookFolderNaming.cleanedFolderName(fromFileBaseName: name)
            guard cleaned != name, !cleaned.isEmpty else { return nil }
            return Rename(oldName: name, newName: cleaned)
        }
        .sorted { $0.oldName < $1.oldName }
    }

    /// Move one folder to its clean name, then the managed original file inside
    /// it (`new/old.ext` → `new/new.ext`), so the two rewrite rules the store
    /// applies both find their targets. Returns false, having moved nothing,
    /// when the clean name is already taken.
    static func performRename(
        _ rename: Rename,
        in booksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let oldFolder = booksDirectory.appendingPathComponent(rename.oldName, isDirectory: true)
        let newFolder = booksDirectory.appendingPathComponent(rename.newName, isDirectory: true)
        guard fileManager.fileExists(atPath: oldFolder.path) else { return false }
        guard !fileManager.fileExists(atPath: newFolder.path) else { return false }
        try fileManager.moveItem(at: oldFolder, to: newFolder)

        // The original book file, named after the folder by the importer. It is
        // not referenced by any row, so a failure here is logged by the caller
        // and costs nothing but an odd file name.
        if let children = try? fileManager.contentsOfDirectory(atPath: newFolder.path) {
            for child in children where (child as NSString).deletingPathExtension == rename.oldName {
                let ext = (child as NSString).pathExtension
                let cleanName = ext.isEmpty ? rename.newName : "\(rename.newName).\(ext)"
                let source = newFolder.appendingPathComponent(child)
                let destination = newFolder.appendingPathComponent(cleanName)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        return true
    }
}
