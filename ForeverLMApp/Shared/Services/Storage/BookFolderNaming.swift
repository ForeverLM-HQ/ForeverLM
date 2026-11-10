import CryptoKit
import Foundation

/// Folder and file names for imported books, derived from the file the learner
/// handed us.
///
/// Anna's Archive names every download
/// `Title -- Author -- Edition, Place, Year -- Publisher -- isbn13 … -- <md5> -- Anna’s Archive`.
/// Keeping that whole string as the book's folder under `Books/`, as the managed
/// copy's file name, and therefore inside every chapter URL, cover path and
/// CloudKit record, would show the learner a clean title in the app while Finder
/// and the database carried the archive's tag. A tagged name is reduced to its
/// title segment; every other name is kept as it is.
enum BookFolderNaming {
    static let segmentSeparator = " -- "

    /// Whether a file base name ends in the archive's tag segment.
    static func isArchiveTaggedName(_ base: String) -> Bool {
        guard let last = base.components(separatedBy: segmentSeparator).last else { return false }
        return isArchiveTag(last)
    }

    /// The folder (and managed file) base name to use for a book file.
    ///
    /// An untagged name comes back byte-for-byte: the folder is the book's
    /// identity on disk and in every chapter URL, so a name this did not
    /// recognise must not be trimmed or normalised in passing.
    static func cleanedFolderName(fromFileBaseName base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.components(separatedBy: segmentSeparator)
        guard segments.count >= 2, let last = segments.last, isArchiveTag(last) else { return base }

        let title = segments[0].trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "_-."))
        )
        if !title.isEmpty { return title }

        // No usable title segment: at least drop the tag and the md5 before it.
        var kept = Array(segments.dropLast())
        if let hash = kept.last, isMD5(hash.trimmingCharacters(in: .whitespaces)) {
            kept.removeLast()
        }
        let fallback = kept.joined(separator: segmentSeparator).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? base : fallback
    }

    private static func isArchiveTag(_ segment: String) -> Bool {
        let folded = segment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "`", with: "'")
        return folded == "anna's archive" || folded == "annas archive"
    }

    private static func isMD5(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy(\.isHexDigit)
    }
}

/// Which book a file being added is, and where the library's copy of it goes.
///
/// A file is a book already in the library only when it is that book's file:
/// the library's own copy itself, a file this Mac added before (its sha256 is
/// in `book_file_digests`), or the same bytes as the copy of a book added
/// before those were kept; or when the learner chose the book it replaces the
/// file of. Never by its title or its name. Add Book matched a book by title
/// until 2026-10-13, so a 1957 monograph called "Bioenergetics" took the row
/// of a textbook with that title and archived its chapters (product owner,
/// 2026-10-12: "There was another book called Bioenergetics. That is a
/// textbook, but that seems to have gotten overwritten by this one that's
/// also called Bioenergetics").
///
/// A new book gets a folder of its own, never one that is on disk or that a
/// chapter's file or address names, so it never writes over another book's
/// file and never takes the addresses, and so the ids, of another book's
/// chapters: the file's name, else that name and the first eight characters
/// of the file's sha256 (`Bioenergetics 4545308b`).
struct BookFilePlacement: Equatable, Sendable {
    enum Copy: Equatable, Sendable {
        /// The file is the library's copy already.
        case none
        /// Copied to `destPath`, where nothing is.
        case new
        /// Copied over the book's file at `destPath`: the learner chose the
        /// book this file replaces the file of.
        case replace
    }

    /// The book the file is, or nil for a new book.
    let bookID: String?
    let bookDir: String
    let destPath: String
    let copy: Copy

    /// - Parameters:
    ///   - importPath: the file being added (an EPUB Apple Books keeps as a folder is a folder).
    ///   - digest: its sha256 (`BookFilePlacement.sha256Hex(ofBookAt:)`).
    ///   - recordedBookID: the book of the learner's own library that `digest` was added as, if
    ///     that book still has a chapter.
    ///   - replacingBookID: the book the learner chose this file to replace the file of.
    ///   - bookFolders: each book of the learner's own library with a chapter, and the folder
    ///     under `booksDir` its chapters' file is in.
    ///   - foldersInUse: the folders under `Books/` any chapter names, lowercased
    ///     (`KnowledgeStore.bookFolderNamesInUse`).
    static func decide(
        importPath: String,
        digest: String,
        booksDir: String,
        recordedBookID: String?,
        replacingBookID: String?,
        bookFolders: [String: String],
        foldersInUse: Set<String>,
        fileManager: FileManager = .default
    ) -> BookFilePlacement {
        let source = URL(fileURLWithPath: importPath).standardizedFileURL
        let books = URL(fileURLWithPath: booksDir, isDirectory: true).standardizedFileURL
        let fileExtension = source.pathExtension

        func namedFile(in folder: String) -> String {
            let name = (folder as NSString).lastPathComponent
            return (folder as NSString).appendingPathComponent(fileExtension.isEmpty ? name : "\(name).\(fileExtension)")
        }
        func newFolder() -> String {
            var base = BookFolderNaming.cleanedFolderName(
                fromFileBaseName: source.deletingPathExtension().lastPathComponent
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "Book" }
            let name = freeFolderName(base, digest: digest) { candidate in
                foldersInUse.contains(candidate.lowercased())
                    || fileManager.fileExists(atPath: books.appendingPathComponent(candidate).path)
            }
            return books.appendingPathComponent(name, isDirectory: true).path
        }
        func isFolder(_ a: String, _ b: String) -> Bool {
            URL(fileURLWithPath: a).standardizedFileURL.path.lowercased()
                == URL(fileURLWithPath: b).standardizedFileURL.path.lowercased()
        }
        let ownBooks = bookFolders.sorted { $0.key < $1.key }

        // The learner chose the book this file is the file of.
        if let bookID = replacingBookID {
            guard let folder = bookFolders[bookID] else {
                let folder = newFolder()
                return BookFilePlacement(bookID: bookID, bookDir: folder, destPath: namedFile(in: folder), copy: .new)
            }
            let current = existingBookFile(in: folder, fileExtension: fileExtension, fileManager: fileManager)
            return BookFilePlacement(
                bookID: bookID,
                bookDir: folder,
                destPath: current ?? namedFile(in: folder),
                copy: current == nil ? .new : .replace
            )
        }

        // A file already in the library's folder, added where it is: the book
        // whose folder it is in, or a new book there.
        let parent = source.deletingLastPathComponent()
        if parent.deletingLastPathComponent().path == books.path {
            let owner = ownBooks.first { isFolder($0.value, parent.path) }?.key
            return BookFilePlacement(bookID: owner, bookDir: parent.path, destPath: source.path, copy: .none)
        }

        // A file added before: its sha256 names the book. The library's copy
        // may have been rewritten since, and stays as it is.
        if let bookID = recordedBookID {
            guard let folder = bookFolders[bookID] else {
                let folder = newFolder()
                return BookFilePlacement(bookID: bookID, bookDir: folder, destPath: namedFile(in: folder), copy: .new)
            }
            let current = existingBookFile(in: folder, fileExtension: fileExtension, fileManager: fileManager)
            return BookFilePlacement(
                bookID: bookID,
                bookDir: folder,
                destPath: current ?? namedFile(in: folder),
                copy: current == nil ? .new : .none
            )
        }

        // A book added before sha256s were kept: the same bytes as its copy.
        for (bookID, folder) in ownBooks {
            for candidate in bookFiles(in: folder, fileExtension: fileExtension, fileManager: fileManager)
            where sameBytes(candidate, source.path, fileManager: fileManager) {
                return BookFilePlacement(bookID: bookID, bookDir: folder, destPath: candidate, copy: .none)
            }
        }

        let folder = newFolder()
        return BookFilePlacement(bookID: nil, bookDir: folder, destPath: namedFile(in: folder), copy: .new)
    }

    /// `base` when nothing has it, else `base` and the first eight characters
    /// of `digest`, numbered when even that is taken (a book of the same file
    /// was removed, and its chapters still name the folder).
    static func freeFolderName(_ base: String, digest: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(base) else { return base }
        let tagged = "\(base) \(digest.prefix(8))"
        guard isTaken(tagged) else { return tagged }
        var number = 2
        while isTaken("\(tagged) \(number)") { number += 1 }
        return "\(tagged) \(number)"
    }

    /// The folder under `booksDir` that a chapter's file at `path` (absolute)
    /// is in, or nil: a file outside `booksDir`, or one right in it.
    static func bookFolder(ofFileAt path: String, booksDir: String) -> String? {
        let books = URL(fileURLWithPath: booksDir, isDirectory: true).standardizedFileURL.path
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        guard file.hasPrefix(books + "/") else { return nil }
        let inside = file.dropFirst(books.count + 1).split(separator: "/")
        guard inside.count >= 2 else { return nil }
        return (books as NSString).appendingPathComponent(String(inside[0]))
    }

    /// The sha256 of a book file, lowercase hex. An EPUB that Apple Books
    /// keeps as a folder is hashed as its files: each one's path inside it and
    /// its own sha256, in path order, hidden files left out.
    static func sha256Hex(ofBookAt path: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        guard isDirectory.boolValue else {
            return try SourceFileHash.sha256Hex(ofFileAt: URL(fileURLWithPath: path))
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        var files: [(path: String, digest: String)] = []
        while let url = walker.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let inside = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            files.append((inside, try SourceFileHash.sha256Hex(ofFileAt: url)))
        }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data("\(file.path)\u{0}\(file.digest)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The book's file in its folder with this extension: the one named for
    /// the folder, else the only one.
    private static func existingBookFile(in folder: String, fileExtension: String, fileManager: FileManager) -> String? {
        let files = bookFiles(in: folder, fileExtension: fileExtension, fileManager: fileManager)
        let named = (folder as NSString).appendingPathComponent(
            "\((folder as NSString).lastPathComponent).\(fileExtension)"
        )
        if let match = files.first(where: { $0.lowercased() == named.lowercased() }) { return match }
        return files.count == 1 ? files[0] : nil
    }

    /// The files right in `folder` with this extension, in name order.
    private static func bookFiles(in folder: String, fileExtension: String, fileManager: FileManager) -> [String] {
        guard !fileExtension.isEmpty else { return [] }
        return ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == fileExtension.lowercased() }
            .sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// Two regular files with the same bytes: the sizes first, then the contents.
    private static func sameBytes(_ a: String, _ b: String, fileManager: FileManager) -> Bool {
        guard let first = try? fileManager.attributesOfItem(atPath: a),
              let second = try? fileManager.attributesOfItem(atPath: b),
              first[.type] as? FileAttributeType == .typeRegular,
              second[.type] as? FileAttributeType == .typeRegular,
              (first[.size] as? NSNumber) == (second[.size] as? NSNumber) else { return false }
        return fileManager.contentsEqual(atPath: a, andPath: b)
    }
}
