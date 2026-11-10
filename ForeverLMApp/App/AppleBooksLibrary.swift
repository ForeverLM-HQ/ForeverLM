// Reading the Apple Books library.
import AppKit
import SwiftUI

// MARK: - Apple Books

/// The books a learner already keeps in Apple Books, read from Apple Books'
/// own index so the guide can offer them by title. Books synced through
/// iCloud live in the iBooks ubiquity container as unpacked `.epub` folders,
/// which `importBook` reads directly; a book iCloud has not downloaded is
/// counted rather than offered, because reading it would stall on the fetch.
enum AppleBooksLibrary {
    struct Book: Identifiable, Hashable, Sendable {
        let path: String
        let title: String
        let author: String?
        var id: String { path }
    }

    struct Scan: Sendable {
        var books: [Book]
        var cloudOnlyCount: Int
    }

    static let supportedExtensions: Set<String> = ["epub", "pdf"]

    static func scan(homeDir: String = BookmarkAccessManager.realHomeDirectory) -> Scan {
        let indexPath = (homeDir as NSString).appendingPathComponent(
            "Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/Books.plist"
        )
        let entries: [Book]
        if let data = FileManager.default.contents(atPath: indexPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let rows = plist["Books"] as? [[String: Any]] {
            entries = books(fromIndex: rows)
        } else {
            let folder = (homeDir as NSString).appendingPathComponent(
                "Library/Mobile Documents/iCloud~com~apple~iBooks/Documents"
            )
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            entries = names
                .filter { supportedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .map { name in
                    Book(
                        path: (folder as NSString).appendingPathComponent(name),
                        title: (name as NSString).deletingPathExtension,
                        author: nil
                    )
                }
        }

        var seen: Set<String> = []
        var available: [Book] = []
        var cloudOnly: Set<String> = []
        for book in entries {
            let key = "\(book.title.lowercased())\u{1F}\(book.author?.lowercased() ?? "")"
            guard !seen.contains(key) else { continue }
            if isDownloaded(book.path) {
                seen.insert(key)
                cloudOnly.remove(key)
                available.append(book)
            } else if FileManager.default.fileExists(atPath: book.path) {
                cloudOnly.insert(key)
            }
        }
        available.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Scan(books: available, cloudOnlyCount: cloudOnly.count)
    }

    /// Apple Books keeps one row per copy, so a book imported twice appears
    /// twice; previews are samples, not the book.
    static func books(fromIndex rows: [[String: Any]]) -> [Book] {
        rows.compactMap { row in
            guard (row["isPreview"] as? Bool) != true,
                  let path = row["path"] as? String,
                  supportedExtensions.contains((path as NSString).pathExtension.lowercased())
            else { return nil }
            let title = (row["itemName"] as? String)
                ?? (row["BKDisplayName"] as? String)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let author = (row["artistName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Book(path: path, title: title, author: author)
        }
    }

    private static func isDownloaded(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]) else { return false }
        guard values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }
}
