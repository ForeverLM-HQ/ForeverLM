// browse_library: the Library page of the ForeverLM view inside Claude, Codex and ChatGPT.
import AppKit
import Foundation

extension MCPDataStore {
    /// Thumbnails are drawn this many pixels on their longer side: the view
    /// shows them at 40 points, twice that for a Retina screen.
    static let browseLibraryThumbnailPixels: CGFloat = 96

    /// The library as the Mac's Library lists it, for the web view an assistant
    /// draws (`workers/mcp-gateway/src/sidebar-app.ts`): newest first, a book
    /// or course once under its own title and cover rather than chapter by
    /// chapter (product owner, 2026-11-22: "the books show up not as books but
    /// as chapters"), and every row with its picture as a JPEG data URL,
    /// because the view's sandbox can load nothing from this Mac and the
    /// artwork hosts are not on its list ("also no thumbnails at all").
    func browseLibrary(text: String?, sourceType: String?, limit: Int) async throws -> String {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedType = sourceType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var family: [String] = []
        if !trimmedType.isEmpty {
            guard let found = StudioSourceType.searchFamily(named: trimmedType) else {
                throw MCPError.invalidInput("Unknown source_type '\(trimmedType)'. Use one of: \(StudioSourceType.searchFamilyNames.joined(separator: ", ")).")
            }
            family = found
        }
        let rows = try matchingSourceRows(
            scope: nil,
            author: nil,
            titleContains: nil,
            text: trimmedText.isEmpty ? nil : trimmedText,
            sourceTypeFamily: family,
            includeArchived: false
        )

        // Fold chapters and lectures into their book or course, at the place
        // of the newest one, as the Library's Books and Courses tabs do.
        struct Entry {
            var kind: String
            var groupID: String?
            var rows: [[String: Any]]
        }
        var entries: [Entry] = []
        var groupIndex: [String: Int] = [:]
        for row in rows {
            let type = row["source_type"] as? String ?? ""
            if type == StudioSourceType.book.rawValue || type == StudioSourceType.course.rawValue,
               let groupID = row["group_id"] as? String, !groupID.isEmpty {
                let key = "\(type):\(groupID)"
                if let index = groupIndex[key] {
                    entries[index].rows.append(row)
                } else {
                    groupIndex[key] = entries.count
                    entries.append(Entry(kind: type, groupID: groupID, rows: [row]))
                }
            } else {
                entries.append(Entry(kind: "source", groupID: nil, rows: [row]))
            }
        }

        // Hiding one source is presentation state: the source remains available
        // to chat and search. The app view still needs the bit so it can match
        // the Mac Library's visible list and its Hidden Items fold instead of
        // presenting a hidden book as though it were visible.
        var visibleEntries: [Entry] = []
        var hiddenEntries: [Entry] = []
        for entry in entries {
            let hiddenRows = entry.rows.filter { ($0["is_hidden"] as? Int) == 1 }
            if hiddenRows.count == entry.rows.count {
                hiddenEntries.append(entry)
            } else {
                visibleEntries.append(entry)
                // A chapter hidden on its own stays under its visible book in
                // the native list, and appears separately in Hidden Items.
                for row in hiddenRows {
                    hiddenEntries.append(Entry(kind: "source", groupID: nil, rows: [row]))
                }
            }
        }

        let pageLimit = max(1, min(limit, 400))
        let shownVisible = Array(visibleEntries.prefix(pageLimit))
        let shownHidden = Array(hiddenEntries.prefix(pageLimit))
        let shown = shownVisible.map { (entry: $0, hidden: false) }
            + shownHidden.map { (entry: $0, hidden: true) }
        let store = try knowledgeStore()
        let coverPaths = shown.contains(where: { $0.entry.kind == StudioSourceType.book.rawValue })
            ? (try? store.loadBooks().coverPaths) ?? [:]
            : [:]
        let bookIDs = shown
            .filter { $0.entry.kind == StudioSourceType.book.rawValue }
            .compactMap { $0.entry.groupID }
        // A book row opens where the Library's own book row does: the chapter
        // the reader would resume, or the first one.
        let resumeChapters: [String: String] = bookIDs.isEmpty ? [:] : await MainActor.run {
            guard let studio = try? AppModelBridge.requireStudio() else { return [:] }
            var found: [String: String] = [:]
            for bookID in bookIDs {
                if let chapter = studio.resumeBookChapter(for: bookID) { found[bookID] = chapter.id }
            }
            return found
        }

        let dayFormatter = Self.sourceFilterDayFormatter()
        var items: [[String: Any]] = []
        var origins: [Int: SourceArtwork.Origin] = [:]
        for (index, listing) in shown.enumerated() {
            let entry = listing.entry
            guard let newest = entry.rows.first else { continue }
            var item: [String: Any] = [:]
            item["is_hidden"] = listing.hidden
            let words = entry.rows.reduce(0) { $0 + ($1["word_count"] as? Int ?? 0) }
            if words > 0 { item["words"] = words }
            if let added = newest["date_added"] as? Double {
                item["added"] = dayFormatter.string(from: Date(timeIntervalSinceReferenceDate: added))
            }
            if let groupID = entry.groupID {
                item["kind"] = entry.kind
                item["type"] = entry.kind
                item["group_id"] = groupID
                item["source_ids"] = entry.rows.compactMap { $0["id"] as? String }
                item["title"] = (newest["group_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
                item["parts"] = entry.rows.count
                if let subtitle = newest["group_subtitle"] as? String, !subtitle.isEmpty { item["subtitle"] = subtitle }
                if let byline = newest["author"] as? String, !byline.isEmpty { item["byline"] = byline }
                let opening = resumeChapters[groupID] ?? (entry.rows.last?["id"] as? String) ?? (newest["id"] as? String ?? "")
                item["id"] = opening
                if let cover = coverPaths[groupID] {
                    origins[index] = .file(cover)
                } else if let article = try? store.loadSourceForSync(opening) {
                    origins[index] = SourceArtwork.origin(for: article)
                }
            } else {
                let id = newest["id"] as? String ?? ""
                let type = newest["source_type"] as? String ?? ""
                item["kind"] = "source"
                item["id"] = id
                item["type"] = type
                item["title"] = (newest["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
                var byline: [String] = []
                if type == StudioSourceType.podcast.rawValue || type == StudioSourceType.video.rawValue,
                   let show = newest["domain"] as? String, !show.isEmpty {
                    byline.append(show)
                } else if let author = newest["author"] as? String, !author.isEmpty {
                    byline.append(Self.browseShortAuthors(author))
                }
                if let journal = newest["journal"] as? String, !journal.isEmpty { byline.append(journal) }
                if let year = newest["published_year"].map({ "\($0)" }), !year.isEmpty, year != "0" { byline.append(year) }
                if !byline.isEmpty { item["byline"] = byline.joined(separator: " · ") }
                if let article = try? store.loadSourceForSync(id) {
                    origins[index] = SourceArtwork.origin(for: article)
                }
            }
            items.append(item)
        }

        // Every picture at once: each is cached on disk after its first
        // drawing, so only a page never seen before waits on the network.
        let thumbnails: [Int: String] = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, origin) in origins {
                group.addTask {
                    guard let image = await SourceArtwork.thumbnail(for: origin, maxPixelSize: Self.browseLibraryThumbnailPixels) else {
                        return (index, nil)
                    }
                    return (index, SourceArtwork.jpegDataURL(from: image, quality: 0.78))
                }
            }
            var found: [Int: String] = [:]
            for await (index, url) in group { if let url { found[index] = url } }
            return found
        }
        for (index, url) in thumbnails where index < items.count {
            items[index]["thumbnail"] = url
        }

        let visibleCount = shownVisible.count
        return try jsonString([
            "total": visibleEntries.count,
            "items": Array(items.prefix(visibleCount)),
            "hidden_total": hiddenEntries.count,
            "hidden_items": Array(items.dropFirst(visibleCount)),
        ])
    }

    /// "Smith et al." for a paper with many authors, as the Library's rows say it.
    static func browseShortAuthors(_ byline: String) -> String {
        let names = byline.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.count > 2 ? "\(names[0]) et al." : names.joined(separator: ", ")
    }
}
