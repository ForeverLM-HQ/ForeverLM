import Foundation

/// Reads the saved-article exports of read-later apps, once, without a connector.
///
/// Every read-later app exports in one of a few shapes, so the contract is the
/// shape rather than the app: a CSV with a URL column (Readwise Reader,
/// Instapaper, Pocket, Raindrop), a browser bookmarks HTML file (Pocket,
/// Raindrop, Readwise, any browser), a JSON export whose records carry a URL
/// (Omnivore), or a plain list of links. A folder is searched for all of them,
/// which covers an unzipped multi-file export. Identity is the URL alone; the
/// title, date and read state are carried over when the export has them, and
/// the normal article fetch fills in the rest. Call off the main actor.
enum ReadLaterExportImportService {
    struct Entry: Sendable, Equatable {
        let url: String
        var title: String?
        var dateAdded: Date?
        var isRead: Bool
    }

    struct Inventory: Sendable {
        let entries: [Entry]
        let warnings: [String]
    }

    enum ImportError: LocalizedError {
        case nothingFound(String)

        var errorDescription: String? {
            switch self {
            case .nothingFound(let name):
                return "No saved articles were found in \(name). Choose the CSV, HTML or JSON file your read-later app exported."
            }
        }
    }

    static let supportedExtensions: Set<String> = ["csv", "html", "htm", "json", "txt"]

    static func inventory(from selections: [URL]) throws -> Inventory {
        var files: [URL] = []
        var warnings: [String] = []
        for selection in selections {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory) else {
                warnings.append("\(selection.lastPathComponent) is no longer available.")
                continue
            }
            if isDirectory.boolValue {
                files.append(contentsOf: exportFiles(in: selection))
            } else if supportedExtensions.contains(selection.pathExtension.lowercased()) {
                files.append(selection)
            } else {
                warnings.append("Skipped unsupported file \(selection.lastPathComponent).")
            }
        }

        var entries: [Entry] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                warnings.append("Could not read \(file.lastPathComponent).")
                continue
            }
            switch file.pathExtension.lowercased() {
            case "csv": entries.append(contentsOf: parseCSV(text))
            case "html", "htm": entries.append(contentsOf: parseBookmarksHTML(text))
            case "json": entries.append(contentsOf: parseJSON(data))
            default: entries.append(contentsOf: parseURLList(text))
            }
        }

        let deduplicated = deduplicate(entries)
        if deduplicated.isEmpty, let first = selections.first {
            throw ImportError.nothingFound(first.lastPathComponent)
        }
        return Inventory(entries: deduplicated, warnings: warnings)
    }

    private static func exportFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator where supportedExtensions.contains(file.pathExtension.lowercased()) {
            files.append(file)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// First occurrence wins its place in the order; later copies of the same
    /// URL only fill what it lacked, and a read mark from either sticks.
    private static func deduplicate(_ entries: [Entry]) -> [Entry] {
        var results: [Entry] = []
        var indexByURL: [String: Int] = [:]
        for entry in entries {
            let key = URLNormalizer.normalize(entry.url)
            if let index = indexByURL[key] {
                if results[index].title == nil { results[index].title = entry.title }
                if results[index].dateAdded == nil { results[index].dateAdded = entry.dateAdded }
                results[index].isRead = results[index].isRead || entry.isRead
            } else {
                indexByURL[key] = results.count
                results.append(entry)
            }
        }
        return results
    }

    // MARK: - CSV

    private static let urlColumns = ["url", "link", "href", "given_url", "resolved_url", "original_url", "source_url", "source url", "original url"]
    private static let titleColumns = ["title", "name", "resolved_title", "given_title"]
    private static let dateColumns = ["time_added", "saved date", "saved_at", "savedat", "created", "created_at", "date added", "date_added", "timestamp", "added", "date"]
    private static let stateColumns = ["status", "state", "folder", "location"]
    private static let readFlagColumns = ["is_read", "read", "archived", "is_archived"]

    static func parseCSV(_ text: String) -> [Entry] {
        let rows = csvRows(text)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ names: [String]) -> Int? {
            for name in names { if let index = columns.firstIndex(of: name) { return index } }
            return nil
        }

        let body = Array(rows.dropFirst())
        let urlIndex = column(urlColumns) ?? columns.indices.first { index in
            // A header this list does not name: take the column whose values are links.
            body.prefix(20).contains { row in index < row.count && httpURL(row[index]) != nil }
        }
        guard let urlIndex else { return [] }
        let titleIndex = column(titleColumns)
        let dateIndex = column(dateColumns)
        let stateIndex = column(stateColumns)
        let readIndex = column(readFlagColumns)

        return body.compactMap { row in
            func value(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let cleaned = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
            guard let url = value(urlIndex).flatMap(httpURL) else { return nil }
            let state = value(stateIndex)?.lowercased()
            // An unsaved feed item in a reader that also follows feeds was never saved.
            if state == "feed" { return nil }
            let isRead = state.map(isArchiveState) == true
                || value(readIndex).map { ["1", "true", "yes"].contains($0.lowercased()) } == true
            let title = value(titleIndex).flatMap { $0 == url ? nil : $0 }
            return Entry(url: url, title: title, dateAdded: value(dateIndex).flatMap(parseDate), isRead: isRead)
        }
    }

    private static func isArchiveState(_ state: String) -> Bool {
        ["archive", "archived", "read"].contains(state)
    }

    /// RFC 4180: fields separated by commas, quoted with `"`, a doubled quote
    /// inside quotes is a literal one, and newlines may sit inside quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()
        if pending == "\u{FEFF}" { pending = iterator.next() }
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"": quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            default: field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: - Bookmarks HTML

    /// The Netscape bookmark format every browser and read-later app exports:
    /// `<A HREF="…" ADD_DATE="…">Title</A>`, grouped under `<H1>`/`<H3>`
    /// headings. A heading naming an archive (Pocket's "Read Archive") marks
    /// the links under it as read.
    static func parseBookmarksHTML(_ text: String) -> [Entry] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<h[1-6][^>]*>(.*?)</h[1-6]>|<a\s([^>]*)>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let nsText = text as NSString
        var entries: [Entry] = []
        var underArchive = false
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            if match.range(at: 1).location != NSNotFound {
                underArchive = decodeHTML(nsText.substring(with: match.range(at: 1))).lowercased().contains("archive")
                continue
            }
            let attributes = nsText.substring(with: match.range(at: 2))
            guard let href = htmlAttribute("href", in: attributes).flatMap(httpURL) else { continue }
            let title = decodeHTML(nsText.substring(with: match.range(at: 3)))
            let added = htmlAttribute("add_date", in: attributes)
                ?? htmlAttribute("time_added", in: attributes)
            entries.append(Entry(
                url: href,
                title: title.isEmpty || title == href ? nil : title,
                dateAdded: added.flatMap(parseDate),
                isRead: underArchive
            ))
        }
        return entries
    }

    private static func htmlAttribute(_ name: String, in attributes: String) -> String? {
        guard let pattern = try? NSRegularExpression(
            pattern: #"(?:^|\s)"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsAttributes = attributes as NSString
        guard let match = pattern.firstMatch(in: attributes, range: NSRange(location: 0, length: nsAttributes.length)) else {
            return nil
        }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return decodeHTML(nsAttributes.substring(with: match.range(at: group)))
        }
        return nil
    }

    private static func decodeHTML(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON

    /// Any JSON export whose records are objects carrying a URL, at any depth.
    static func parseJSON(_ data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var entries: [Entry] = []
        collectJSONEntries(root, into: &entries)
        return entries
    }

    private static func collectJSONEntries(_ value: Any, into entries: inout [Entry]) {
        if let array = value as? [Any] {
            for element in array { collectJSONEntries(element, into: &entries) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let keys = Dictionary(object.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func string(_ names: [String]) -> String? {
            for name in names {
                if let value = keys[name] as? String, !value.isEmpty { return value }
                if let value = keys[name] as? NSNumber { return value.stringValue }
            }
            return nil
        }
        let jsonURLKeys = ["url", "originalurl", "original_url", "link", "href", "source_url", "given_url", "resolved_url"]
        if let url = string(jsonURLKeys).flatMap(httpURL) {
            let state = string(["state", "status", "location", "folder"])?.lowercased()
            guard state != "feed" else { return }
            let readFlag = ["isarchived", "is_archived", "archived", "is_read", "isread"].contains { name in
                (keys[name] as? Bool) == true || (keys[name] as? NSNumber)?.boolValue == true
            }
            let title = string(["title", "name", "resolved_title", "given_title"])
            entries.append(Entry(
                url: url,
                title: title == url ? nil : title,
                dateAdded: string(["savedat", "saved_at", "created_at", "createdat", "time_added", "date_added", "dateadded", "created"]).flatMap(parseDate),
                isRead: readFlag || state.map(isArchiveState) == true
            ))
            return
        }
        for nested in object.values where nested is [Any] || nested is [String: Any] {
            collectJSONEntries(nested, into: &entries)
        }
    }

    // MARK: - Plain list

    static func parseURLList(_ text: String) -> [Entry] {
        text.components(separatedBy: .newlines).compactMap { line in
            httpURL(line).map { Entry(url: $0, title: nil, dateAdded: nil, isRead: false) }
        }
    }

    // MARK: - Shared

    private static func httpURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return trimmed
    }

    /// Unix seconds or milliseconds, ISO 8601, or `yyyy-MM-dd HH:mm:ss`.
    static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(value), number > 0 {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
