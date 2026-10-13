import Foundation
import ZIPFoundation

/// An EPUB book is one file: the library keeps `Books/<folder>/<name>.epub`
/// and nothing unpacked beside it (product owner, 2026-10-12: "make sure all
/// the books are just stored as one pdf or epub").
///
/// A chapter keeps the address it had when books were unpacked into a
/// `Chapters` folder, `Books/<folder>/Chapters/<entry>`: it is the address of
/// `<entry>` inside the book's file, whose root is what that folder held. So a
/// chapter's id, its reading position (an entry and a fraction), its
/// highlights and everything else keyed by its address stay as they were.
/// Code that reads a chapter's document, a picture or a stylesheet reads it
/// here: the file itself while a book is still unpacked (until it is packed,
/// `pack`), else the entry of the book's file.
enum EPUBBookFiles {
    /// Where an address under a book's `Chapters` lives once the book is one
    /// file.
    struct Location: Equatable, Sendable {
        /// The book's `.epub`, absolute.
        let book: String
        /// The entry's path inside it.
        let entry: String
    }

    /// The folder a book's entries are addressed under.
    static let rootName = "Chapters"

    /// The book file and entry `path` names, when `path` is under a book's
    /// `Chapters` and the book is kept as one file (no such folder on disk).
    /// Nil for any other path, and while the book is still unpacked.
    static func location(ofPath path: String) -> Location? {
        guard let (chapters, entry) = split(path), !isDirectory(chapters) else { return nil }
        let folder = (chapters as NSString).deletingLastPathComponent
        guard let book = bookFile(inFolder: folder) else { return nil }
        return Location(book: book, entry: entry)
    }

    /// `path` as the `Chapters` folder it is under and its path inside it.
    static func split(_ path: String) -> (chapters: String, entry: String)? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let range = standardized.range(of: "/\(rootName)/", options: .backwards) else { return nil }
        let entry = String(standardized[range.upperBound...])
        guard !entry.isEmpty else { return nil }
        return (String(standardized[..<range.lowerBound]) + "/\(rootName)", entry)
    }

    /// The book's one file in its folder: `<folder>.epub` when there is one,
    /// else the folder's only `.epub`. Nil when there is none, or more than
    /// one and none named for the folder.
    static func bookFile(inFolder folder: String) -> String? {
        let named = (folder as NSString).appendingPathComponent((folder as NSString).lastPathComponent + ".epub")
        if isFile(named) { return named }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.lowercased().hasSuffix(".epub") && !$0.hasPrefix(".") }
            .map { (folder as NSString).appendingPathComponent($0) }
            .filter(isFile)
        return files.count == 1 ? files[0] : nil
    }

    // MARK: Reading

    /// The bytes at `path`: the file on disk, else the entry of the book file
    /// it is addressed in. Nil when neither holds it.
    static func contents(atPath path: String) -> Data? {
        if isFile(path) { return FileManager.default.contents(atPath: path) }
        guard let location = location(ofPath: path) else { return nil }
        return entry(location.entry, inBook: location.book)
    }

    /// A document's text: UTF-8, else Latin-1, as a few older EPUB exports are.
    static func text(atPath path: String) -> String? {
        guard let data = contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func exists(atPath path: String) -> Bool {
        if isFile(path) { return true }
        guard let location = location(ofPath: path) else { return false }
        return index(of: location.book)?.entries[location.entry] != nil
    }

    /// One entry of the book file at `book`, read whole and checked against its
    /// CRC-32. Nil when the entry is not there or does not read back whole.
    static func entry(_ name: String, inBook book: String) -> Data? {
        guard let index = index(of: book), let record = index.entries[name] else { return nil }
        return EPUBParser.zipEntryContents(record, in: index.data)
    }

    /// Every entry name of the book file at `book`, in the archive's order.
    static func entryNames(inBook book: String) -> [String]? {
        index(of: book)?.names
    }

    private final class Index {
        let data: Data
        let names: [String]
        let entries: [String: EPUBParser.ZIPEntryRecord]

        init(data: Data, records: [EPUBParser.ZIPEntryRecord]) {
            self.data = data
            names = records.map(\.name)
            entries = Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The book files read lately, mapped, with their central directories,
    /// keyed by path, size and modification date: a book packed again is read
    /// afresh.
    private nonisolated(unsafe) static let indexes: NSCache<NSString, Index> = {
        let cache = NSCache<NSString, Index>()
        cache.countLimit = 8
        return cache
    }()

    private static func index(of book: String) -> Index? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: book),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(book)|\(size)|\(modified)" as NSString
        if let cached = indexes.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: book), options: .alwaysMapped),
              let records = EPUBParser.zipCentralDirectory(data) else { return nil }
        let index = Index(data: data, records: records)
        indexes.setObject(index, forKey: key)
        return index
    }

    // MARK: Packing

    /// Where the book unpacked in `folder` is packed to: the book's file when
    /// it has one (`<folder>.epub` first, else the folder's only `.epub`, a
    /// file or an EPUB once unpacked under that name), else `<folder>.epub`
    /// made new. `original` is that file when it is a file, whose entries the
    /// folder lacks are kept.
    static func packingTarget(inFolder folder: String) -> (destination: URL, original: URL?) {
        let named = (folder as NSString).appendingPathComponent((folder as NSString).lastPathComponent + ".epub")
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.lowercased().hasSuffix(".epub") && !$0.hasPrefix(".") }
            .map { (folder as NSString).appendingPathComponent($0) }
        let destination = FileManager.default.fileExists(atPath: named) || candidates.count != 1 ? named : candidates[0]
        return (URL(fileURLWithPath: destination), isFile(destination) ? URL(fileURLWithPath: destination) : nil)
    }

    enum PackError: Error, LocalizedError, Equatable {
        case nothingToPack(String)
        case readBackFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToPack(let folder): return "The book folder holds nothing to pack: \(folder)"
            case .readBackFailed(let entry): return "The book's packed file did not read back \(entry) as it was written."
            }
        }
    }

    /// Writes the book whose files are in the unpacked folder `chapters` as one
    /// file at `destination`: every file of the folder under its path in it,
    /// and every entry of `original` (the book's own file, when it is one) the
    /// folder does not hold, so nothing either had is lost. `mimetype` comes
    /// first and stored, as EPUB requires. Every entry is read back before the
    /// file is moved into place. `skipping` names files of the folder that are
    /// not the book's (a page the reader once wrote there).
    static func pack(
        _ chapters: URL,
        original: URL?,
        to destination: URL,
        skipping: Set<String> = []
    ) throws {
        let fileManager = FileManager.default
        var files: [(name: String, url: URL)] = []
        if let walker = fileManager.enumerator(at: chapters, includingPropertiesForKeys: [.isRegularFileKey]) {
            let root = chapters.standardizedFileURL.path
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root + "/") else { continue }
                let name = String(path.dropFirst(root.count + 1))
                guard url.lastPathComponent != ".DS_Store", !url.lastPathComponent.hasPrefix("._"),
                      !skipping.contains(name) else { continue }
                files.append((name, url))
            }
        }
        files.sort { $0.name < $1.name }
        let held = Set(files.map(\.name))
        var fromOriginal: [(name: String, data: Data)] = []
        if let original, let data = try? Data(contentsOf: original, options: .alwaysMapped),
           let records = EPUBParser.zipCentralDirectory(data) {
            for record in records where !record.name.hasSuffix("/") && !held.contains(record.name) {
                if let contents = EPUBParser.zipEntryContents(record, in: data) {
                    fromOriginal.append((record.name, contents))
                }
            }
        }
        guard !files.isEmpty || !fromOriginal.isEmpty else { throw PackError.nothingToPack(chapters.path) }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).packing.epub")
        defer { try? fileManager.removeItem(at: staging) }
        let archive = try Archive(url: staging, accessMode: .create)
        let mimetype = files.first { $0.name == "mimetype" }.flatMap { fileManager.contents(atPath: $0.url.path) }
            ?? fromOriginal.first { $0.name == "mimetype" }?.data
            ?? Data("application/epub+zip".utf8)
        try add("mimetype", mimetype, to: archive, compressed: false)
        for file in files where file.name != "mimetype" {
            guard let data = fileManager.contents(atPath: file.url.path) else { continue }
            try add(file.name, data, to: archive, compressed: true)
        }
        for entry in fromOriginal where entry.name != "mimetype" {
            try add(entry.name, entry.data, to: archive, compressed: true)
        }

        // Read back with the reader the app reads books with, byte for byte.
        guard let written = try? Data(contentsOf: staging, options: .alwaysMapped),
              let records = EPUBParser.zipCentralDirectory(written) else { throw PackError.readBackFailed("the archive") }
        let byName = Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard records.first?.name == "mimetype" else { throw PackError.readBackFailed("mimetype") }
        for file in files {
            guard let record = byName[file.name],
                  EPUBParser.zipEntryContents(record, in: written) == fileManager.contents(atPath: file.url.path) else {
                throw PackError.readBackFailed(file.name)
            }
        }
        for entry in fromOriginal {
            guard let record = byName[entry.name], EPUBParser.zipEntryContents(record, in: written) == entry.data else {
                throw PackError.readBackFailed(entry.name)
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            if isDirectory(destination.path) {
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: staging, to: destination)
            } else {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            }
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    private static func add(_ name: String, _ data: Data, to archive: Archive, compressed: Bool) throws {
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressed ? .deflate : .none,
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        )
    }

    // MARK: Files

    private static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
