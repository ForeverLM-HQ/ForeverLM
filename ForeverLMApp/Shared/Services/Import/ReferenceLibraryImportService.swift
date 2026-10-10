import CoreGraphics
import Foundation
import SQLite3
#if canImport(PDFKit)
import PDFKit
#endif

/// A highlight or note another app made on a PDF, on its way to becoming a
/// ForeverLM highlight.
///
/// It carries what the other app recorded: the page, the rectangles the mark
/// covers in PDF page space, the words when the app kept them, and the
/// comment. `originKey` names where it came from (`zotero:<annotation key>`,
/// or the page and geometry of a mark saved inside the file), and the
/// highlight's id is derived from it, so importing the same library twice
/// adds nothing the second time.
struct ImportedPDFMark: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Marked words: a highlight, an underline, a strikeout.
        case passage
        /// A comment pinned to a spot on the page, with no words marked.
        case pinnedNote
    }

    var kind: Kind
    /// Zero-based, in the PDF's own page numbering.
    var pageIndex: Int
    var rects: [CGRect]
    /// The marked words as the other app read them; nil when it kept none.
    var text: String?
    var comment: String
    var color: SourceHighlightColor
    var createdAt: Date?
    var originKey: String
}

/// Reads reference-manager exports without mutating the source library.
///
/// Zotero data directories are opened read-only. BibTeX and RIS cover every
/// other reference manager — Paperpile, Mendeley, EndNote, JabRef, ReadCube —
/// including the PDF attachment paths their exports carry. All parsing and
/// directory traversal must be called off the main actor.
///
/// Zotero keeps the highlights and notes made in its reader in its database,
/// not in the PDF, so they are read here with the paper (`Entry.marks`). The
/// other managers' marks reach ForeverLM only when they are saved inside the
/// PDF, which the PDF import reads for every paper.
enum ReferenceLibraryImportService {
    struct Entry: Sendable, Equatable {
        let recordID: String
        let sourceName: String
        var title: String
        var authors: String?
        var journal: String?
        var year: String?
        var doi: String?
        var url: String?
        var pdfPath: String?
        var dateAdded: Date?
        /// Highlights and notes the reference manager keeps outside the PDF,
        /// measured against `pdfPath`. Only Zotero has any.
        var marks: [ImportedPDFMark] = []

        var stableCatalogURL: String {
            if let doi = Self.cleanedDOI(doi) {
                return "https://doi.org/\(doi)"
            }
            if let url = Self.cleanedHTTPURL(url) {
                return url
            }
            let source = sourceName
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "library"
            let key = recordID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? recordID
            return "reference-library://\(source)/\(key)"
        }

        var destinationFilename: String {
            let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            let cleanTitle = title
                .components(separatedBy: invalid)
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let titlePart = String((cleanTitle.isEmpty ? "Paper" : cleanTitle).prefix(120))
            let keyPart = String(recordID.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init)
                .prefix(16))
            return keyPart.isEmpty ? "\(titlePart).pdf" : "\(titlePart) [\(keyPart)].pdf"
        }

        fileprivate static func cleanedDOI(_ value: String?) -> String? {
            guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] where value.lowercased().hasPrefix(prefix) {
                value.removeFirst(prefix.count)
                break
            }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        fileprivate static func cleanedHTTPURL(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: value),
                  url.scheme == "http" || url.scheme == "https" else { return nil }
            return value
        }
    }

    struct Inventory: Sendable {
        let entries: [Entry]
        let warnings: [String]
    }

    enum ImportError: LocalizedError {
        case unsupportedSelection(String)
        case unreadableExport(String)
        case invalidZoteroDatabase(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSelection(let name):
                return "No Zotero library, BibTeX or RIS export, or PDFs were found in \(name)."
            case .unreadableExport(let name):
                return "Could not read the reference-library export \(name)."
            case .invalidZoteroDatabase(let detail):
                return "Could not read the Zotero library (\(detail)). Quit Zotero and try again, or export the library as BibTeX or RIS and import that file instead."
            }
        }
    }

    /// The Zotero data directory on this Mac, if it holds a readable
    /// `zotero.sqlite`. Zotero records a moved data directory in its profile's
    /// `prefs.js` (`extensions.zotero.dataDir`, honoured only with
    /// `extensions.zotero.useDataDir`); otherwise it lives at `~/Zotero`.
    /// `prefs.js` is Zotero's own machine-written file, one `user_pref` call a
    /// line, so reading the two keys out of it is parsing a format, not
    /// guessing at prose. Call off the main actor.
    static func zoteroDataDirectory(homeDir: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        let profiles = URL(fileURLWithPath: homeDir)
            .appendingPathComponent("Library/Application Support/Zotero/Profiles", isDirectory: true)
        for profile in (try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [] {
            guard let prefs = try? String(contentsOf: profile.appendingPathComponent("prefs.js"), encoding: .utf8) else {
                continue
            }
            let values = zoteroPreferences(in: prefs)
            if values["extensions.zotero.useDataDir"] == "true",
               let path = values["extensions.zotero.dataDir"], !path.isEmpty {
                candidates.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        candidates.append(URL(fileURLWithPath: homeDir).appendingPathComponent("Zotero", isDirectory: true))
        return candidates.first { fm.isReadableFile(atPath: $0.appendingPathComponent("zotero.sqlite").path) }
    }

    /// `user_pref("key", value);` lines from a Firefox-style `prefs.js`, with
    /// string values unquoted and unescaped.
    static func zoteroPreferences(in prefs: String) -> [String: String] {
        var values: [String: String] = [:]
        let pattern = #"^user_pref\("([^"]+)",\s*(.+)\);\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return values }
        let range = NSRange(prefs.startIndex..., in: prefs)
        for match in regex.matches(in: prefs, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: prefs),
                  let valueRange = Range(match.range(at: 2), in: prefs) else { continue }
            var value = prefs[valueRange].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            values[String(prefs[keyRange])] = value
        }
        return values
    }

    static func inventory(from selections: [URL]) throws -> Inventory {
        var entries: [Entry] = []
        var warnings: [String] = []
        var genericExportFiles: [URL] = []
        var genericPDFs: [URL] = []

        for selection in selections {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory) else {
                warnings.append("\(selection.lastPathComponent) is no longer available.")
                continue
            }

            if isDirectory.boolValue {
                let zoteroDatabase = selection.appendingPathComponent("zotero.sqlite")
                if FileManager.default.fileExists(atPath: zoteroDatabase.path) {
                    let library = try loadZoteroLibrary(zoteroDatabase, dataDirectory: selection)
                    entries.append(contentsOf: library.entries)
                    warnings.append(contentsOf: library.warnings)
                    continue
                }
                let files = try supportedFiles(in: selection)
                genericExportFiles.append(contentsOf: files.filter { exportExtensions.contains($0.pathExtension.lowercased()) })
                genericPDFs.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "pdf" })
                continue
            }

            let ext = selection.pathExtension.lowercased()
            if selection.lastPathComponent == "zotero.sqlite" {
                let library = try loadZoteroLibrary(selection, dataDirectory: selection.deletingLastPathComponent())
                entries.append(contentsOf: library.entries)
                warnings.append(contentsOf: library.warnings)
            } else if exportExtensions.contains(ext) {
                genericExportFiles.append(selection)
            } else if ext == "pdf" {
                genericPDFs.append(selection)
            } else {
                warnings.append("Skipped unsupported file \(selection.lastPathComponent).")
            }
        }

        var referencedPDFs = Set<String>()
        for export in stableUniqueURLs(genericExportFiles) {
            let parsed: [Entry]
            switch export.pathExtension.lowercased() {
            case "bib", "bibtex": parsed = try loadBibTeX(export)
            case "ris": parsed = try loadRIS(export)
            default: parsed = []
            }
            for entry in parsed {
                if let pdfPath = entry.pdfPath {
                    referencedPDFs.insert(URL(fileURLWithPath: pdfPath).standardizedFileURL.path)
                }
            }
            entries.append(contentsOf: parsed)
        }

        // Append loose PDFs after catalog records. The importer can then attach a
        // PDF to the metadata-only row by DOI/title instead of creating a sibling.
        for pdf in stableUniqueURLs(genericPDFs) {
            let path = pdf.standardizedFileURL.path
            guard !referencedPDFs.contains(path) else { continue }
            entries.append(standalonePDFEntry(pdf))
        }

        let deduplicated = deduplicate(entries)
        if deduplicated.isEmpty, let first = selections.first {
            throw ImportError.unsupportedSelection(first.lastPathComponent)
        }
        return Inventory(entries: deduplicated, warnings: warnings)
    }

    private static let exportExtensions: Set<String> = ["bib", "bibtex", "ris"]

    private static func supportedFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            if exportExtensions.contains(ext) || ext == "pdf" {
                files.append(file)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func stableUniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func deduplicate(_ entries: [Entry]) -> [Entry] {
        var results: [Entry] = []
        var indexByKey: [String: Int] = [:]
        for entry in entries {
            let key: String
            if let doi = Entry.cleanedDOI(entry.doi) {
                key = "doi:\(doi.lowercased())"
            } else if let url = Entry.cleanedHTTPURL(entry.url) {
                key = "url:\(url.lowercased())"
            } else {
                key = "record:\(entry.sourceName.lowercased()):\(entry.recordID.lowercased())"
            }
            if let index = indexByKey[key] {
                var existing = results[index]
                if existing.pdfPath == nil {
                    existing.pdfPath = entry.pdfPath
                    existing.marks = entry.marks
                } else if existing.marks.isEmpty, existing.pdfPath == entry.pdfPath {
                    existing.marks = entry.marks
                }
                if existing.authors == nil { existing.authors = entry.authors }
                if existing.journal == nil { existing.journal = entry.journal }
                if existing.year == nil { existing.year = entry.year }
                if existing.doi == nil { existing.doi = entry.doi }
                if existing.url == nil { existing.url = entry.url }
                if existing.dateAdded == nil { existing.dateAdded = entry.dateAdded }
                results[index] = existing
            } else {
                indexByKey[key] = results.count
                results.append(entry)
            }
        }
        return results
    }

    // MARK: - BibTeX

    static func loadBibTeX(_ url: URL) throws -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadableExport(url.lastPathComponent)
        }
        return parseBibTeX(text, baseDirectory: url.deletingLastPathComponent())
    }

    static func parseBibTeX(_ text: String, baseDirectory: URL) -> [Entry] {
        let records = bibRecords(in: text)
        let paperTypes: Set<String> = [
            "article", "conference", "inproceedings", "incollection", "proceedings",
            "preprint", "thesis", "phdthesis", "mastersthesis", "techreport", "report",
            "unpublished", "misc"
        ]
        return records.compactMap { record in
            guard paperTypes.contains(record.type),
                  let rawTitle = record.fields["title"],
                  let title = cleanBibValue(rawTitle), !title.isEmpty else { return nil }
            let doi = cleanBibValue(record.fields["doi"])
            let rawURL = cleanBibValue(record.fields["url"])
            let url = rawURL?.isEmpty == false ? rawURL : nil
            let rawAuthors = cleanBibValue(record.fields["author"])
            let authors = rawAuthors.map(normalizeBibTeXAuthors)
            let journal = firstNonempty([
                record.fields["journal"], record.fields["booktitle"], record.fields["publisher"],
                record.fields["school"], record.fields["institution"]
            ].map(cleanBibValue))
            let year = publicationYear(firstNonempty([
                cleanBibValue(record.fields["year"]), cleanBibValue(record.fields["date"])
            ]))
            let pdfPath = resolveBibTeXPDF(record.fields["file"], baseDirectory: baseDirectory)
            return Entry(
                recordID: record.key,
                sourceName: "BibTeX",
                title: title,
                authors: authors?.isEmpty == false ? authors : nil,
                journal: journal,
                year: year,
                doi: doi,
                url: url,
                pdfPath: pdfPath,
                dateAdded: nil
            )
        }
    }

    private struct BibRecord {
        let type: String
        let key: String
        let fields: [String: String]
    }

    private static func bibRecords(in text: String) -> [BibRecord] {
        var records: [BibRecord] = []
        var cursor = text.startIndex
        while let at = text[cursor...].firstIndex(of: "@") {
            var index = text.index(after: at)
            skipWhitespace(text, &index)
            let typeStart = index
            while index < text.endIndex, text[index].isLetter { index = text.index(after: index) }
            let type = text[typeStart..<index].lowercased()
            skipWhitespace(text, &index)
            guard index < text.endIndex, text[index] == "{" || text[index] == "(" else {
                cursor = index
                continue
            }
            let open = text[index]
            let close: Character = open == "{" ? "}" : ")"
            let bodyStart = text.index(after: index)
            guard let bodyEnd = matchingDelimiter(in: text, from: index, open: open, close: close) else { break }
            let body = String(text[bodyStart..<bodyEnd])
            if !["string", "comment", "preamble"].contains(type), let record = parseBibBody(body, type: type) {
                records.append(record)
            }
            cursor = text.index(after: bodyEnd)
        }
        return records
    }

    private static func parseBibBody(_ body: String, type: String) -> BibRecord? {
        var index = body.startIndex
        guard let comma = topLevelComma(in: body, from: index) else { return nil }
        let key = body[index..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        index = body.index(after: comma)
        var fields: [String: String] = [:]
        while index < body.endIndex {
            skipWhitespaceAndCommas(body, &index)
            guard index < body.endIndex else { break }
            let nameStart = index
            while index < body.endIndex, body[index].isLetter || body[index].isNumber || body[index] == "_" || body[index] == "-" {
                index = body.index(after: index)
            }
            let name = body[nameStart..<index].lowercased()
            skipWhitespace(body, &index)
            guard !name.isEmpty, index < body.endIndex, body[index] == "=" else {
                if index < body.endIndex { index = body.index(after: index) }
                continue
            }
            index = body.index(after: index)
            skipWhitespace(body, &index)
            let valueStart = index
            var braceDepth = 0
            var quoted = false
            var escaped = false
            while index < body.endIndex {
                let character = body[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"", braceDepth == 0 {
                    quoted.toggle()
                } else if !quoted {
                    if character == "{" { braceDepth += 1 }
                    if character == "}" { braceDepth = max(0, braceDepth - 1) }
                    if character == ",", braceDepth == 0 { break }
                }
                index = body.index(after: index)
            }
            fields[String(name)] = body[valueStart..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            if index < body.endIndex { index = body.index(after: index) }
        }
        return BibRecord(type: type, key: key, fields: fields)
    }

    private static func matchingDelimiter(
        in text: String,
        from start: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var index = start
        var depth = 0
        var quoted = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted {
                if character == open { depth += 1 }
                if character == close {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func topLevelComma(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var quoted = false
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character == "{" { depth += 1 }
                if character == "}" { depth = max(0, depth - 1) }
                if character == ",", depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func cleanBibValue(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.first == "{", value.last == "}" || value.first == "\"", value.last == "\"" {
            value.removeFirst()
            value.removeLast()
        }
        value = value
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\%", with: "%")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\#", with: "#")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizeBibTeXAuthors(_ authors: String) -> String {
        authors
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    /// The `file` field follows the JabRef convention every manager writes:
    /// attachments separated by `;`, each `description:path:type`, with `\:`
    /// and `\;` escaping separators inside a path. Zotero writes
    /// `Full Text:files/12/x.pdf:application/pdf`, Mendeley Desktop
    /// `:Users/me/x.pdf:pdf` with the leading slash dropped, and Paperpile or a
    /// hand-kept file often a bare path. Every plausible reading is tried, and
    /// only one naming an existing PDF is kept, so a wrong split costs nothing.
    private static func resolveBibTeXPDF(_ raw: String?, baseDirectory: URL) -> String? {
        guard let raw = cleanBibValue(raw) else { return nil }
        for attachment in splitUnescaped(raw, on: ";") {
            let parts = splitUnescaped(attachment.trimmingCharacters(in: .whitespacesAndNewlines), on: ":")
            var candidates: [String] = []
            if parts.count >= 3 { candidates.append(parts[1..<(parts.count - 1)].joined(separator: ":")) }
            candidates.append(parts.joined(separator: ":"))
            if parts.count >= 2 {
                candidates.append(parts.dropFirst().joined(separator: ":"))
                candidates.append(parts.dropLast().joined(separator: ":"))
            }
            for escaped in candidates {
                let candidate = unescapeBibFilePath(escaped)
                if let path = resolvePDFPath(candidate, baseDirectory: baseDirectory) { return path }
                if !candidate.hasPrefix("/"), !candidate.lowercased().hasPrefix("file:"),
                   let path = resolvePDFPath("/" + candidate, baseDirectory: baseDirectory) {
                    return path
                }
            }
        }
        return nil
    }

    /// Splits on `separator` wherever it is not backslash-escaped, keeping the
    /// escapes so a later split still sees them.
    private static func splitUnescaped(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func unescapeBibFilePath(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - RIS

    static func loadRIS(_ url: URL) throws -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadableExport(url.lastPathComponent)
        }
        return parseRIS(text, baseDirectory: url.deletingLastPathComponent())
    }

    static func parseRIS(_ text: String, baseDirectory: URL) -> [Entry] {
        var records: [[String: [String]]] = []
        var current: [String: [String]] = [:]
        var lastTag: String?
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.count >= 5 {
                let tag = String(rawLine.prefix(2)).uppercased()
                let separator = rawLine.dropFirst(2).prefix(3)
                if separator == "  -" {
                    let value = rawLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    if tag == "ER" {
                        if !current.isEmpty { records.append(current) }
                        current = [:]
                        lastTag = nil
                    } else {
                        current[tag, default: []].append(value)
                        lastTag = tag
                    }
                    continue
                }
            }
            if let lastTag, !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               var values = current[lastTag], !values.isEmpty {
                values[values.count - 1] += " " + rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                current[lastTag] = values
            }
        }
        if !current.isEmpty { records.append(current) }

        let paperTypes: Set<String> = ["JOUR", "CONF", "CPAPER", "THES", "RPRT", "UNPB", "GEN"]
        return records.enumerated().compactMap { offset, fields in
            let type = fields["TY"]?.first?.uppercased() ?? "GEN"
            guard paperTypes.contains(type),
                  let title = firstRIS(fields, ["TI", "T1", "CT"]), !title.isEmpty else { return nil }
            let authors = (fields["AU"] ?? fields["A1"] ?? [])
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            let journal = firstRIS(fields, ["JO", "JF", "JA", "T2", "PB"])
            let date = firstRIS(fields, ["PY", "Y1", "DA"])
            let doi = firstRIS(fields, ["DO"])
            let url = firstRIS(fields, ["UR"])
            let recordID = firstRIS(fields, ["ID", "AN"])
                ?? doi ?? url ?? "ris-\(offset)-\(title)"
            let pdfPath = (fields["L1"] ?? fields["L2"] ?? [])
                .lazy.compactMap { resolvePDFPath($0, baseDirectory: baseDirectory) }.first
            return Entry(
                recordID: recordID,
                sourceName: "RIS",
                title: title,
                authors: authors.isEmpty ? nil : authors,
                journal: journal,
                year: publicationYear(date),
                doi: doi,
                url: url,
                pdfPath: pdfPath,
                dateAdded: nil
            )
        }
    }

    private static func firstRIS(_ fields: [String: [String]], _ keys: [String]) -> String? {
        for key in keys {
            if let value = fields[key]?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Zotero SQLite

    private struct ZoteroBuilder {
        let itemID: Int64
        let key: String
        let dateAdded: Date?
        var fields: [String: String] = [:]
        var authors: [String] = []
        var pdfPath: String?
        /// The attachment item `pdfPath` came from; Zotero files a reader
        /// annotation under the attachment, not under the paper.
        var pdfAttachmentID: Int64?
    }

    /// Reads the Zotero database, or a snapshot of it while Zotero is open:
    /// a running Zotero holds its database under an exclusive lock, so the
    /// read-only open succeeds and the first query reports it locked. Copying
    /// the file is not blocked by that lock, and the snapshot is read and
    /// discarded, so the library itself is still never written.
    static func loadZoteroDatabase(_ databaseURL: URL, dataDirectory: URL) throws -> [Entry] {
        try loadZoteroLibrary(databaseURL, dataDirectory: dataDirectory).entries
    }

    /// The papers, plus a warning when their highlights could not be read:
    /// a paper still imports without its marks rather than not at all.
    static func loadZoteroLibrary(_ databaseURL: URL, dataDirectory: URL) throws -> (entries: [Entry], warnings: [String]) {
        do {
            return try readZoteroDatabase(databaseURL, dataDirectory: dataDirectory)
        } catch ImportError.invalidZoteroDatabase(let detail)
            where detail.localizedCaseInsensitiveContains("locked") || detail.localizedCaseInsensitiveContains("busy") {
            let snapshotDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZoteroSnapshot-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
            let snapshot = snapshotDirectory.appendingPathComponent("zotero.sqlite")
            do {
                try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: databaseURL, to: snapshot)
            } catch {
                throw ImportError.invalidZoteroDatabase(detail)
            }
            return try readZoteroDatabase(snapshot, dataDirectory: dataDirectory)
        }
    }

    private static func readZoteroDatabase(_ databaseURL: URL, dataDirectory: URL) throws -> (entries: [Entry], warnings: [String]) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database could not be opened"
            if let database { sqlite3_close(database) }
            throw ImportError.invalidZoteroDatabase(detail)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        let paperTypes = ["journalArticle", "conferencePaper", "thesis", "preprint", "manuscript", "report", "document"]
        let typeList = paperTypes.map { "'\($0)'" }.joined(separator: ",")
        var builders: [Int64: ZoteroBuilder] = [:]
        do {
            try query(database, """
                SELECT i.itemID, i.key, i.dateAdded, f.fieldName, v.value
                FROM items i
                JOIN itemTypes t ON t.itemTypeID = i.itemTypeID
                LEFT JOIN deletedItems d ON d.itemID = i.itemID
                LEFT JOIN itemData data ON data.itemID = i.itemID
                LEFT JOIN fields f ON f.fieldID = data.fieldID
                LEFT JOIN itemDataValues v ON v.valueID = data.valueID
                WHERE d.itemID IS NULL AND t.typeName IN (\(typeList))
                ORDER BY i.itemID
                """) { statement in
                    let itemID = sqlite3_column_int64(statement, 0)
                    let key = sqliteText(statement, 1) ?? String(itemID)
                    var builder: ZoteroBuilder
                    if let existing = builders[itemID] {
                        builder = existing
                    } else {
                        let dateAdded = sqliteText(statement, 2).flatMap(parseZoteroDate)
                        builder = ZoteroBuilder(itemID: itemID, key: key, dateAdded: dateAdded)
                    }
                    if let field = sqliteText(statement, 3), let value = sqliteText(statement, 4), !value.isEmpty {
                        builder.fields[field] = value
                    }
                    builders[itemID] = builder
                }

            try query(database, """
                SELECT ic.itemID, c.firstName, c.lastName, c.fieldMode
                FROM itemCreators ic
                JOIN creators c ON c.creatorID = ic.creatorID
                JOIN creatorTypes ct ON ct.creatorTypeID = ic.creatorTypeID
                WHERE ct.creatorType = 'author'
                ORDER BY ic.itemID, ic.orderIndex
                """) { statement in
                    let itemID = sqlite3_column_int64(statement, 0)
                    guard var builder = builders[itemID] else { return }
                    let first = sqliteText(statement, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let last = sqliteText(statement, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fieldMode = sqlite3_column_int(statement, 3)
                    let display = fieldMode == 1 ? last : [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                    if !display.isEmpty { builder.authors.append(display) }
                    builders[itemID] = builder
                }

            try query(database, """
                SELECT a.parentItemID, attachment.key, a.path, a.itemID
                FROM itemAttachments a
                JOIN items attachment ON attachment.itemID = a.itemID
                LEFT JOIN deletedItems d ON d.itemID = attachment.itemID
                WHERE a.parentItemID IS NOT NULL
                  AND d.itemID IS NULL
                  AND (lower(COALESCE(a.contentType, '')) = 'application/pdf'
                       OR lower(COALESCE(a.path, '')) LIKE '%.pdf')
                ORDER BY a.parentItemID, attachment.itemID
                """) { statement in
                    let parentID = sqlite3_column_int64(statement, 0)
                    guard var builder = builders[parentID], builder.pdfPath == nil,
                          let attachmentKey = sqliteText(statement, 1),
                          let rawPath = sqliteText(statement, 2),
                          let path = resolveZoteroAttachment(
                              rawPath,
                              attachmentKey: attachmentKey,
                              dataDirectory: dataDirectory
                          ) else { return }
                    builder.pdfPath = path
                    builder.pdfAttachmentID = sqlite3_column_int64(statement, 3)
                    builders[parentID] = builder
                }
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.invalidZoteroDatabase(error.localizedDescription)
        }

        var warnings: [String] = []
        var marksByAttachment: [Int64: [ImportedPDFMark]] = [:]
        do {
            marksByAttachment = try readZoteroAnnotations(database)
        } catch {
            warnings.append("Could not read Zotero's highlights and notes (\(error.localizedDescription)); the papers were imported without them.")
        }

        var entries = builders.values.sorted { $0.itemID < $1.itemID }.compactMap { builder -> Entry? in
            guard let title = builder.fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let journal = firstNonempty([
                builder.fields["publicationTitle"], builder.fields["conferenceName"],
                builder.fields["publisher"], builder.fields["university"],
                builder.fields["institution"], builder.fields["repository"]
            ])
            return Entry(
                recordID: builder.key,
                sourceName: "Zotero",
                title: title,
                authors: builder.authors.isEmpty ? nil : builder.authors.joined(separator: "; "),
                journal: journal,
                year: publicationYear(builder.fields["date"]),
                doi: builder.fields["DOI"],
                url: builder.fields["url"],
                pdfPath: builder.pdfPath,
                dateAdded: builder.dateAdded,
                marks: builder.pdfAttachmentID.flatMap { marksByAttachment[$0] } ?? []
            )
        }

        // Standalone PDFs have no parent bibliographic row but are still papers
        // in a Zotero library. Import them through the normal PDF path.
        try query(database, """
            SELECT attachment.key, a.path, a.itemID
            FROM itemAttachments a
            JOIN items attachment ON attachment.itemID = a.itemID
            LEFT JOIN deletedItems d ON d.itemID = attachment.itemID
            WHERE a.parentItemID IS NULL
              AND d.itemID IS NULL
              AND (lower(COALESCE(a.contentType, '')) = 'application/pdf'
                   OR lower(COALESCE(a.path, '')) LIKE '%.pdf')
            ORDER BY attachment.itemID
            """) { statement in
                guard let key = sqliteText(statement, 0),
                      let rawPath = sqliteText(statement, 1),
                      let path = resolveZoteroAttachment(rawPath, attachmentKey: key, dataDirectory: dataDirectory) else { return }
                var entry = standalonePDFEntry(URL(fileURLWithPath: path))
                entry = Entry(
                    recordID: key,
                    sourceName: "Zotero",
                    title: entry.title,
                    authors: nil,
                    journal: nil,
                    year: nil,
                    doi: entry.doi,
                    url: nil,
                    pdfPath: path,
                    dateAdded: nil,
                    marks: marksByAttachment[sqlite3_column_int64(statement, 2)] ?? []
                )
                entries.append(entry)
            }
        return (entries, warnings)
    }

    /// Zotero's `itemAnnotations.type` values that carry words or a comment.
    /// Image (3) and ink (4) marks have neither, so they have nothing to bring.
    private enum ZoteroAnnotationType: Int32 {
        case highlight = 1
        case note = 2
        case underline = 5
        case text = 6
    }

    /// `itemAnnotations.position` for a PDF: rectangles as `[x1, y1, x2, y2]`
    /// in PDF page space, the same space PDFKit's page geometry uses. A mark
    /// running onto the next page lists that page's part in `nextPageRects`;
    /// only the first page's part is kept, which is where the mark starts.
    private struct ZoteroPosition: Decodable {
        let pageIndex: Int
        let rects: [[Double]]?
    }

    /// The highlights and notes made in Zotero's own reader, keyed by the PDF
    /// attachment they belong to, in Zotero's reading order.
    ///
    /// `isExternal = 1` rows are marks Zotero found saved inside the PDF
    /// file; the PDF import reads those from the file itself, so they are
    /// skipped here rather than brought in twice. A Zotero older than 6 has no
    /// annotations table and no marks.
    private static func readZoteroAnnotations(_ database: OpaquePointer) throws -> [Int64: [ImportedPDFMark]] {
        var hasTable = false
        try query(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'itemAnnotations'") { _ in
            hasTable = true
        }
        guard hasTable else { return [:] }

        let types = [ZoteroAnnotationType.highlight, .note, .underline, .text].map { String($0.rawValue) }
        var marks: [Int64: [ImportedPDFMark]] = [:]
        try query(database, """
            SELECT ann.parentItemID, item.key, ann.type, ann.text, ann.comment, ann.color, ann.position, item.dateAdded
            FROM itemAnnotations ann
            JOIN items item ON item.itemID = ann.itemID
            LEFT JOIN deletedItems d ON d.itemID = ann.itemID
            WHERE d.itemID IS NULL
              AND ann.isExternal = 0
              AND ann.type IN (\(types.joined(separator: ",")))
            ORDER BY ann.parentItemID, ann.sortIndex, ann.itemID
            """) { statement in
                guard let key = sqliteText(statement, 1),
                      let type = ZoteroAnnotationType(rawValue: sqlite3_column_int(statement, 2)),
                      let positionJSON = sqliteText(statement, 6),
                      let position = try? JSONDecoder().decode(ZoteroPosition.self, from: Data(positionJSON.utf8)),
                      position.pageIndex >= 0 else { return }
                let rects = (position.rects ?? []).compactMap { corners -> CGRect? in
                    guard corners.count == 4 else { return nil }
                    let rect = CGRect(
                        x: min(corners[0], corners[2]),
                        y: min(corners[1], corners[3]),
                        width: abs(corners[2] - corners[0]),
                        height: abs(corners[3] - corners[1])
                    )
                    return rect.isEmpty ? nil : rect
                }
                guard !rects.isEmpty else { return }
                let text = sqliteText(statement, 3)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let comment = sqliteText(statement, 4)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let kind: ImportedPDFMark.Kind
                switch type {
                case .highlight, .underline: kind = .passage
                case .note, .text: kind = .pinnedNote
                }
                // A pinned note is only its comment; an empty one says nothing.
                if kind == .pinnedNote, comment.isEmpty { return }
                marks[sqlite3_column_int64(statement, 0), default: []].append(ImportedPDFMark(
                    kind: kind,
                    pageIndex: position.pageIndex,
                    rects: rects,
                    text: text?.isEmpty == false ? text : nil,
                    comment: comment,
                    color: SourceHighlightColor(hex: sqliteText(statement, 5)) ?? .default,
                    createdAt: sqliteText(statement, 7).flatMap(parseZoteroDate),
                    originKey: "zotero:\(key)"
                ))
            }
        return marks
    }

    private static func query(
        _ database: OpaquePointer,
        _ sql: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.invalidZoteroDatabase(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw ImportError.invalidZoteroDatabase(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func sqliteText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func resolveZoteroAttachment(
        _ rawPath: String,
        attachmentKey: String,
        dataDirectory: URL
    ) -> String? {
        let candidate: URL
        if rawPath.hasPrefix("storage:") {
            let filename = String(rawPath.dropFirst("storage:".count))
            candidate = dataDirectory.appendingPathComponent("storage/\(attachmentKey)/\(filename)")
        } else if rawPath.hasPrefix("file://"), let fileURL = URL(string: rawPath) {
            candidate = fileURL
        } else if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            // `attachments:` is relative to Zotero's separately configured
            // linked-attachment base directory, which is not stored in this DB.
            return nil
        }
        let path = candidate.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func parseZoteroDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    // MARK: - Shared helpers

    private static func standalonePDFEntry(_ url: URL) -> Entry {
        let path = url.standardizedFileURL.path
        let filenameTitle = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        var title = filenameTitle
        var doi: String?
        #if canImport(PDFKit)
        if let document = PDFDocument(url: url) {
            if let metadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
               !metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let opening = (0..<min(document.pageCount, 3))
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
            doi = PaperService.extractDOI(from: opening)
        }
        #endif
        return Entry(
            recordID: url.lastPathComponent,
            sourceName: "PDF Folder",
            title: title,
            authors: nil,
            journal: nil,
            year: nil,
            doi: doi,
            url: nil,
            pdfPath: path,
            dateAdded: nil
        )
    }

    private static func resolvePDFPath(_ raw: String, baseDirectory: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: URL
        if trimmed.lowercased().hasPrefix("file:"), let fileURL = URL(string: trimmed) {
            candidate = fileURL
        } else if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = baseDirectory.appendingPathComponent(trimmed)
        }
        let path = candidate.standardizedFileURL.path
        guard candidate.pathExtension.lowercased() == "pdf",
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private static func publicationYear(_ value: String?) -> String? {
        guard let value else { return nil }
        var run = ""
        for character in value {
            if character.isNumber {
                run.append(character)
                if run.count == 4, let year = Int(run), (1000...2999).contains(year) {
                    return run
                }
            } else {
                run = ""
            }
        }
        return nil
    }

    private static func firstNonempty(_ values: [String?]) -> String? {
        for value in values {
            if let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private static func skipWhitespace(_ text: String, _ index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
    }

    private static func skipWhitespaceAndCommas(_ text: String, _ index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace || text[index] == "," {
            index = text.index(after: index)
        }
    }
}
