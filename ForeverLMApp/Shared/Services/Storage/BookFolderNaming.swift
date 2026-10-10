import Foundation

/// Folder and file names for imported books, derived from the file the learner
/// handed us.
///
/// Anna's Archive names every download
/// `Title -- Author -- Edition, Place, Year -- Publisher -- isbn13 … -- <md5> -- Anna’s Archive`.
/// The importer used to keep that whole string as the book's folder under
/// `Books/`, as the managed copy's file name, and therefore inside every chapter
/// URL, cover path and CloudKit record. The learner saw a clean title in the app
/// while Finder and the database carried the archive's tag. A tagged name is
/// reduced to its title segment; every other name is kept as it is.
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
