import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers
import ZIPFoundation

private let logger = Logger(subsystem: "com.foreverlm", category: "EPUBParser")

/// Parsed EPUB chapter: title, plain-text content, and original HTML body.
struct EPUBChapter {
    let title: String
    let textContent: String
    /// The original HTML body content (formatting preserved, scripts/styles removed).
    let htmlContent: String
    let order: Int
}

/// Metadata extracted from an EPUB file.
struct EPUBMetadata {
    let title: String?
    let subtitle: String?
    let author: String?
    let edition: String?
}

/// Parses EPUB files (which are ZIP archives) to extract chapters and metadata.
/// Uses `/usr/bin/unzip` for extraction since Foundation lacks a built-in ZIP API.
enum EPUBParser {

    // MARK: - Public API

    /// Extract all chapters from an EPUB file, returning them in spine order.
    static func extractChapters(from epubPath: String) throws -> [EPUBChapter] {
        logger.info("[EPUBParser] extractChapters from: \(epubPath)")
        let tempDir = try unzipEPUB(at: epubPath)
        logger.info("[EPUBParser] Unzipped to: \(tempDir)")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        normalizeExtractedHTMLImageDataURIs(in: tempDir)

        let opfRelPath = try findOPFPath(in: tempDir)
        logger.info("[EPUBParser] OPF path: \(opfRelPath)")
        let opfDir = (tempDir as NSString).appendingPathComponent(
            (opfRelPath as NSString).deletingLastPathComponent
        )
        let opfContent = try String(contentsOfFile:
            (tempDir as NSString).appendingPathComponent(opfRelPath), encoding: .utf8)

        let manifest = parseManifest(from: opfContent)
        let spineIds = parseSpine(from: opfContent)
        var tocEntries = parseTOC(opfContent: opfContent, manifest: manifest, opfDir: opfDir)
        logger.info("[EPUBParser] Manifest: \(manifest.count) items, Spine: \(spineIds.count) items, TOC: \(tocEntries.count) entries")

        // Build ordered list of content file paths from spine
        var spineFiles: [(id: String, path: String)] = []
        for itemId in spineIds {
            guard let href = manifest[itemId] else { continue }
            guard let fullPath = safeResolvedPath(base: opfDir, href: href) else { continue }
            // Skip nav/toc documents
            let lower = href.lowercased()
            if lower.contains("nav") && lower.hasSuffix(".xhtml") { continue }
            if lower.contains("toc") && (lower.hasSuffix(".xhtml") || lower.hasSuffix(".html")) { continue }
            spineFiles.append((id: itemId, path: fullPath))
        }
        logger.info("[EPUBParser] Spine files after filtering: \(spineFiles.count)")

        guard !spineFiles.isEmpty else {
            logger.error("[EPUBParser] No content files found in spine")
            throw EPUBError.noContentFiles
        }

        tocEntries = semanticTOCEntriesIfNeeded(tocEntries, spineFiles: spineFiles)

        // If we have TOC entries, group spine files by TOC chapter boundaries
        if !tocEntries.isEmpty {
            var chapters = buildChaptersFromTOC(
                tocEntries: tocEntries,
                spineFiles: spineFiles,
                opfDir: opfDir,
                includedHrefs: preferredChapterTOCHrefs(tocEntries)
            )
            chapters = improveChapterTitles(chapters: chapters)
            logger.info("[EPUBParser] Built \(chapters.count) chapters from TOC")
            return chapters
        }

        // Fallback: each spine file is a chapter
        let chapters = spineFiles.enumerated().compactMap { idx, item -> EPUBChapter? in
            guard let result = extractTextAndHTML(from: item.path) else {
                logger.warning("[EPUBParser] Could not extract text from: \(item.path)")
                return nil
            }
            // Try to extract a heading from the HTML instead of using the filename
            let title = extractHeading(from: item.path) ?? titleFromFilename(item.path)
            return EPUBChapter(title: title, textContent: result.text, htmlContent: result.html, order: idx)
        }
        logger.info("[EPUBParser] Built \(chapters.count) chapters from spine fallback")
        return chapters
    }

    /// Extract the full EPUB structure to a destination directory, returning ordered chapter info.
    /// The destination directory will contain the complete unzipped EPUB contents (XHTML, CSS, images, fonts).
    /// The caller owns `destDir` — this method does NOT clean it up.
    /// - Parameters:
    ///   - epubPath: Absolute path to the `.epub` file
    ///   - destDir: Destination directory path (parent must exist; `destDir` itself must NOT exist yet)
    /// - Returns: Ordered `[(title, xhtmlPath)]` where `xhtmlPath` is absolute.
    static func extractStructure(from epubPath: String, to destDir: String) throws -> [(title: String, xhtmlPath: String)] {
        logger.info("[EPUBParser] extractStructure from: \(epubPath)")
        let sourceURL = URL(fileURLWithPath: epubPath)
        let destURL = URL(fileURLWithPath: destDir)
        guard !FileManager.default.fileExists(atPath: destDir) else {
            throw EPUBError.unzipFailed("Destination directory already exists: \(destDir)")
        }
        try expandEPUB(from: sourceURL, to: destURL)
        logger.info("[EPUBParser] Unzipped to: \(destDir)")
        normalizeExtractedHTMLImageDataURIs(in: destDir)

        let opfRelPath = try findOPFPath(in: destDir)
        logger.info("[EPUBParser] OPF path: \(opfRelPath)")
        let opfDir = (destDir as NSString).appendingPathComponent(
            (opfRelPath as NSString).deletingLastPathComponent
        )
        let opfContent = try String(
            contentsOfFile: (destDir as NSString).appendingPathComponent(opfRelPath),
            encoding: .utf8
        )

        let manifest = parseManifest(from: opfContent)
        let spineIds = parseSpine(from: opfContent)
        var tocEntries = parseTOC(opfContent: opfContent, manifest: manifest, opfDir: opfDir)
        logger.info("[EPUBParser] Manifest: \(manifest.count) items, Spine: \(spineIds.count) items, TOC: \(tocEntries.count) entries")

        var spineFiles: [(id: String, path: String)] = []
        for itemId in spineIds {
            guard let href = manifest[itemId] else { continue }
            guard let fullPath = safeResolvedPath(base: opfDir, href: href) else { continue }
            let lower = href.lowercased()
            // Skip nav/toc documents
            if lower.contains("nav") && lower.hasSuffix(".xhtml") { continue }
            if lower.contains("toc") && (lower.hasSuffix(".xhtml") || lower.hasSuffix(".html")) { continue }
            spineFiles.append((id: itemId, path: fullPath))
        }
        guard !spineFiles.isEmpty else { throw EPUBError.noContentFiles }

        tocEntries = semanticTOCEntriesIfNeeded(tocEntries, spineFiles: spineFiles)

        if !tocEntries.isEmpty {
            let chapters = try buildStructureFromTOC(
                tocEntries: tocEntries,
                spineFiles: spineFiles,
                destDir: destDir,
                includedHrefs: preferredChapterTOCHrefs(tocEntries)
            )
            logger.info("[EPUBParser] Returning \(chapters.count) chapters from TOC")
            return chapters
        }

        // Fallback: each spine file is its own chapter
        let result: [(title: String, xhtmlPath: String)] = spineFiles.compactMap { item in
            guard FileManager.default.fileExists(atPath: item.path) else { return nil }
            let title = normalizeChapterTitle(extractHeading(from: item.path) ?? titleFromFilename(item.path))
            return (title: title, xhtmlPath: item.path)
        }
        logger.info("[EPUBParser] Returning \(result.count) chapters from spine fallback")
        return result
    }

    /// Map TOC entries to their covered spine range, combining multi-file chapters when needed.
    private static func buildStructureFromTOC(
        tocEntries: [TOCEntry],
        spineFiles: [(id: String, path: String)],
        destDir: String,
        includedHrefs: Set<String>?
    ) throws -> [(title: String, xhtmlPath: String)] {
        var fileToSpineIndex: [String: Int] = [:]
        for (idx, item) in spineFiles.enumerated() {
            let normalized = URL(fileURLWithPath: item.path).lastPathComponent.lowercased()
            fileToSpineIndex[normalized] = idx
        }

        var chapters: [(title: String, startIndex: Int)] = []
        for entry in tocEntries {
            let normalized = URL(fileURLWithPath: entry.href).lastPathComponent.lowercased()
            guard let spineIdx = fileToSpineIndex[normalized] else { continue }
            if chapters.last?.startIndex == spineIdx { continue }
            chapters.append((title: entry.title, startIndex: spineIdx))
        }

        guard !chapters.isEmpty else {
            return spineFiles.map { (title: titleFromFilename($0.path), xhtmlPath: $0.path) }
        }

        let combinedDir = (destDir as NSString).appendingPathComponent("ForeverLMCombinedChapters")
        var result: [(title: String, xhtmlPath: String)] = []
        for (idx, chapter) in chapters.enumerated() {
            guard chapter.startIndex < spineFiles.count,
                  FileManager.default.fileExists(atPath: spineFiles[chapter.startIndex].path) else { continue }
            let chapterHref = URL(fileURLWithPath: spineFiles[chapter.startIndex].path).lastPathComponent.lowercased()
            if let includedHrefs, !includedHrefs.contains(chapterHref) { continue }

            let title = bestChapterTitle(tocTitle: chapter.title, xhtmlPath: spineFiles[chapter.startIndex].path)
            let endIndex = (idx + 1 < chapters.count) ? chapters[idx + 1].startIndex - 1 : spineFiles.count - 1
            guard chapter.startIndex <= endIndex else { continue }

            let chapterFiles = Array(spineFiles[chapter.startIndex...endIndex].map { $0.path })
            if chapterFiles.count == 1 {
                result.append((title: title, xhtmlPath: chapterFiles[0]))
                continue
            }

            try FileManager.default.createDirectory(atPath: combinedDir, withIntermediateDirectories: true)
            let filename = String(
                format: "%02d %@.xhtml",
                idx + 1,
                safeCombinedChapterFilename(fromNormalizedTitle: title)
            )
            let combinedPath = (combinedDir as NSString).appendingPathComponent(filename)
            let combinedHTML = combinedChapterHTML(title: title, chapterFiles: chapterFiles, combinedPath: combinedPath)
            try combinedHTML.write(toFile: combinedPath, atomically: true, encoding: .utf8)
            result.append((title: title, xhtmlPath: combinedPath))
        }
        return result
    }

    /// Older imports wrote HTML5 doctype lines into combined chapter files. Remove
    /// them in place so future loads use `loadFileURL` with correct relative paths.
    static func repairLegacyCombinedChapterDoctype(in chaptersDir: String) {
        let combinedDir = (chaptersDir as NSString).appendingPathComponent("ForeverLMCombinedChapters")
        guard FileManager.default.fileExists(atPath: combinedDir),
              let enumerator = FileManager.default.enumerator(atPath: combinedDir) else { return }

        for case let name as String in enumerator {
            guard name.lowercased().hasSuffix(".xhtml") else { continue }
            let path = (combinedDir as NSString).appendingPathComponent(name)
            repairLegacyCombinedChapterDoctype(at: path)
        }
    }

    static func repairLegacyCombinedChapterDoctype(at chapterPath: String) {
        guard chapterPath.contains("ForeverLMCombinedChapters"),
              chapterPath.lowercased().hasSuffix(".xhtml"),
              var html = try? String(contentsOfFile: chapterPath, encoding: .utf8) else { return }

        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<!doctype html>") else { return }

        if let newline = html.firstIndex(of: "\n") {
            html.removeSubrange(html.startIndex...newline)
        } else {
            html = html.replacingOccurrences(
                of: "<!doctype html>",
                with: "",
                options: [.caseInsensitive, .anchored]
            )
        }
        try? html.write(toFile: chapterPath, atomically: true, encoding: .utf8)
    }

    private static func combinedChapterHTML(title: String, chapterFiles: [String], combinedPath: String) -> String {
        let combinedDir = (combinedPath as NSString).deletingLastPathComponent
        let fragments = chapterFiles.compactMap { path -> String? in
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let body = extractBodyHTML(raw, removesMedia: false)
            return rebaseLocalResourceReferences(in: body, from: path, toDirectory: combinedDir)
        }
        let body = fragments.joined(separator: "\n")
        let bodyContent: String
        if extractHeadingFromHTML("<html><body>\(body)</body></html>") == nil {
            bodyContent = "<h1>\(escapeHTML(title))</h1>\n\(body)"
        } else {
            bodyContent = body
        }
        return """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta content="text/html; charset=utf-8" http-equiv="Content-Type"/>
        <title>\(escapeHTML(title))</title>
        </head>
        <body>
        \(bodyContent)
        </body>
        </html>
        """
    }

    /// Filename fragment for a combined chapter. The `%02d` sort prefix already
    /// encodes spine order, so drop leading chapter numbers from the title text.
    private static func safeCombinedChapterFilename(fromNormalizedTitle title: String) -> String {
        let descriptive = chapterNumberAndTitle(from: title)?.title ?? title
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = descriptive
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Chapter" : String(cleaned.prefix(80))
    }

    /// Extract the cover image data from an EPUB file, if available.
    static func extractCoverImage(from epubPath: String) -> Data? {
        guard let tempDir = try? unzipEPUB(at: epubPath) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        guard let opfRelPath = try? findOPFPath(in: tempDir),
              let opfContent = try? String(contentsOfFile:
                  (tempDir as NSString).appendingPathComponent(opfRelPath), encoding: .utf8) else {
            return nil
        }

        let opfDir = (tempDir as NSString).appendingPathComponent(
            (opfRelPath as NSString).deletingLastPathComponent
        )
        let manifest = parseManifest(from: opfContent)

        // Strategy 1: EPUB3 — manifest item with properties="cover-image"
        let coverImagePattern = #"<item\s+[^>]*properties="[^"]*cover-image[^"]*"[^>]*href="([^"]+)""#
        // Also try href before properties
        let coverImagePattern2 = #"<item\s+[^>]*href="([^"]+)"[^>]*properties="[^"]*cover-image[^"]*""#
        for pattern in [coverImagePattern, coverImagePattern2] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: opfContent, range: NSRange(opfContent.startIndex..<opfContent.endIndex, in: opfContent)),
               let hrefRange = Range(match.range(at: 1), in: opfContent) {
                let href = (String(opfContent[hrefRange]).removingPercentEncoding ?? String(opfContent[hrefRange]))
                guard let imagePath = safeResolvedPath(base: opfDir, href: href) else { continue }
                if let data = FileManager.default.contents(atPath: imagePath) {
                    logger.info("[EPUBParser] Found cover image via cover-image property: \(href)")
                    return data
                }
            }
        }

        // Strategy 2: EPUB2 — <meta name="cover" content="item-id"/>, its
        // attributes in either order (`HTMLTagAttributes`).
        if let coverId = extractMetaContent(attribute: "name", value: "cover", from: opfContent, allowsElementText: false) {
            if let href = manifest[coverId],
               let imagePath = safeResolvedPath(base: opfDir, href: href) {
                if let data = FileManager.default.contents(atPath: imagePath) {
                    logger.info("[EPUBParser] Found cover image via meta cover id: \(coverId)")
                    return data
                }
            }
        }

        logger.info("[EPUBParser] No cover image found")
        return nil
    }

    /// Resolve the first local image referenced by an extracted EPUB chapter.
    /// Imported EPUB chapters are XHTML files inside `Books/<book>/Chapters`,
    /// next to the unzipped image assets. This gives chapter rows a real visual
    /// thumbnail without re-unzipping the source EPUB.
    static func firstImagePath(inXHTMLAt chapterPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: chapterPath),
              let html = String(data: data, encoding: .utf8) else { return nil }

        let patterns = [
            #"<img\b[^>]*\ssrc\s*=\s*["']([^"']+)["']"#,
            #"<img\b[^>]*\sdata-src\s*=\s*["']([^"']+)["']"#,
            #"<image\b[^>]*\s(?:xlink:)?href\s*=\s*["']([^"']+)["']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let reference = String(html[range])
                if let imagePath = resolveImageReference(reference, relativeTo: chapterPath) {
                    return imagePath
                }
            }
        }

        return nil
    }

    /// Extract metadata (title, subtitle, author, edition) from an EPUB file.
    static func extractMetadata(from epubPath: String) -> EPUBMetadata {
        guard let tempDir = try? unzipEPUB(at: epubPath) else {
            return EPUBMetadata(title: nil, subtitle: nil, author: nil, edition: nil)
        }
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        guard let opfRelPath = try? findOPFPath(in: tempDir),
              let opfContent = try? String(contentsOfFile:
                  (tempDir as NSString).appendingPathComponent(opfRelPath), encoding: .utf8) else {
            return EPUBMetadata(title: nil, subtitle: nil, author: nil, edition: nil)
        }

        let title = extractXMLElement("dc:title", from: opfContent)
            ?? extractXMLElement("title", from: opfContent)
        let subtitle = extractMetaContent(property: "subtitle", from: opfContent)
            ?? extractMetaContent(name: "subtitle", from: opfContent)
        let author = extractXMLElement("dc:creator", from: opfContent)
            ?? extractXMLElement("creator", from: opfContent)
        let edition = extractMetaContent(property: "edition", from: opfContent)
            ?? extractMetaContent(name: "edition", from: opfContent)

        return EPUBMetadata(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author?.trimmingCharacters(in: .whitespacesAndNewlines),
            edition: edition?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Errors

    enum EPUBError: LocalizedError {
        case unzipFailed(String)
        case containerNotFound
        case opfNotFound
        case noContentFiles
        case damagedArchive(unreadable: Int, total: Int)

        var errorDescription: String? {
            switch self {
            case .damagedArchive(let unreadable, let total):
                return "the file is damaged, so \(unreadable) of its \(total) parts can’t be read. "
                    + "Download it again and import the new copy."
            case .unzipFailed(let msg): return "Failed to unzip EPUB: \(msg)"
            case .containerNotFound: return "META-INF/container.xml not found in EPUB"
            case .opfNotFound: return "OPF file not found in EPUB"
            case .noContentFiles: return "No content files found in EPUB"
            }
        }
    }

    // MARK: - ZIP Extraction

    private static func unzipEPUB(at path: String) throws -> String {
        logger.info("[EPUBParser] Unzipping: \(path)")
        let tempDir = NSTemporaryDirectory() + "epub_\(UUID().uuidString)"
        let sourceURL = URL(fileURLWithPath: path)
        let destURL = URL(fileURLWithPath: tempDir)

        do {
            try expandEPUB(from: sourceURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw error
        }

        logger.info("[EPUBParser] Unzipped successfully to: \(tempDir)")
        return tempDir
    }

    /// Apple Books keeps every book in its iCloud library as an *unpacked* `.epub`
    /// folder (`mimetype`, `META-INF/`, the OPF and content next to each other),
    /// not as the ZIP container the spec describes. Handing such a folder to
    /// ZIPFoundation fails with `ArchiveError` 13 ("Failed to unzip EPUB") even
    /// though the book is perfectly readable. Treat a directory as already
    /// expanded and copy it into place; only a regular file is a ZIP to unpack.
    static func isDirectoryEPUB(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func expandEPUB(from sourceURL: URL, to destURL: URL) throws {
        if isDirectoryEPUB(at: sourceURL.path) {
            logger.info("[EPUBParser] Source is an unpacked EPUB folder; copying instead of unzipping")
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch {
                logger.error("[EPUBParser] Copying unpacked EPUB folder failed: \(error.localizedDescription)")
                throw EPUBError.unzipFailed(error.localizedDescription)
            }
            return
        }
        if let damage = damagedZIPEntries(at: sourceURL), damage.unreadable > 0 {
            logger.error("[EPUBParser] EPUB is damaged: \(damage.unreadable) of \(damage.total) entries have no local header")
            throw EPUBError.damagedArchive(unreadable: damage.unreadable, total: damage.total)
        }
        do {
            try FileManager.default.unzipItem(at: sourceURL, to: destURL)
        } catch {
            logger.error("[EPUBParser] ZIPFoundation unzip failed: \(error.localizedDescription)")
            throw EPUBError.unzipFailed(error.localizedDescription)
        }
    }

    /// Count the entries whose data is gone. A download that broke part-way can
    /// leave a ZIP whose central directory (at the end of the file) is intact
    /// while a stretch of the file before it is zeroed. ZIPFoundation's entry
    /// iterator ends silently at the first entry whose local header is missing,
    /// so `unzipItem` succeeds having written nothing, and the import then
    /// reports a missing `container.xml`. Walk the central directory and check
    /// each local header's signature, so the learner is told the file is damaged.
    /// Returns nil when the file is not a ZIP this check can read (ZIP64 included);
    /// ZIPFoundation then reports what it finds.
    static func damagedZIPEntries(at url: URL) -> (unreadable: Int, total: Int)? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        func hasSignature(_ signature: [UInt8], at offset: Int) -> Bool {
            offset >= 0 && offset + 4 <= data.count && data[offset..<offset + 4].elementsEqual(signature)
        }

        // The end-of-central-directory record is 22 bytes plus a comment of at most 64 KB.
        let endRecordSize = 22
        guard data.count >= endRecordSize else { return nil }
        let earliest = max(0, data.count - endRecordSize - 0xFFFF)
        guard let endRecord = stride(from: data.count - endRecordSize, through: earliest, by: -1)
            .first(where: { hasSignature([0x50, 0x4B, 0x05, 0x06], at: $0) }) else { return nil }

        let total = u16(endRecord + 10)
        var cursor = u32(endRecord + 16)
        guard total != 0xFFFF, cursor != 0xFFFF_FFFF else { return nil }

        var unreadable = 0
        for _ in 0..<total {
            guard hasSignature([0x50, 0x4B, 0x01, 0x02], at: cursor), cursor + 46 <= data.count else { return nil }
            let localHeader = u32(cursor + 42)
            guard localHeader != 0xFFFF_FFFF else { return nil }
            if !hasSignature([0x50, 0x4B, 0x03, 0x04], at: localHeader) { unreadable += 1 }
            cursor += 46 + u16(cursor + 28) + u16(cursor + 30) + u16(cursor + 32)
        }
        return (unreadable, total)
    }

    // MARK: - OPF Discovery

    private static func findOPFPath(in tempDir: String) throws -> String {
        let containerPath = (tempDir as NSString).appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerPath),
              let containerXML = try? String(contentsOfFile: containerPath, encoding: .utf8) else {
            throw EPUBError.containerNotFound
        }

        // Extract rootfile full-path attribute
        // <rootfile full-path="OEBPS/content.opf" .../>
        guard let match = containerXML.range(of: #"full-path="([^"]+)""#, options: .regularExpression),
              let pathRange = containerXML[match].range(of: #"(?<=")(.*?)(?=")"#, options: .regularExpression) else {
            throw EPUBError.opfNotFound
        }

        let opfRelPath = String(containerXML[pathRange])
        guard let opfFullPath = safeResolvedPath(base: tempDir, href: opfRelPath),
              FileManager.default.fileExists(atPath: opfFullPath) else {
            throw EPUBError.opfNotFound
        }

        return opfRelPath
    }

    // MARK: - OPF Parsing

    /// Parse manifest: item id → href mapping
    private static func parseManifest(from opf: String) -> [String: String] {
        var manifest: [String: String] = [:]
        // Match each <item .../> or <item ...> tag, then extract id/href from its attributes
        let itemPattern = #"<item\s([^>]*?)/?>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: .dotMatchesLineSeparators) else {
            return manifest
        }
        let idPattern = #"id="([^"]+)""#
        let hrefPattern = #"href="([^"]+)""#
        guard let idRegex = try? NSRegularExpression(pattern: idPattern),
              let hrefRegex = try? NSRegularExpression(pattern: hrefPattern) else {
            return manifest
        }
        let range = NSRange(opf.startIndex..<opf.endIndex, in: opf)
        for match in itemRegex.matches(in: opf, range: range) {
            guard let attrsRange = Range(match.range(at: 1), in: opf) else { continue }
            let attrs = String(opf[attrsRange])
            let attrsNS = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
            guard let idMatch = idRegex.firstMatch(in: attrs, range: attrsNS),
                  let idRange = Range(idMatch.range(at: 1), in: attrs),
                  let hrefMatch = hrefRegex.firstMatch(in: attrs, range: attrsNS),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: attrs) else { continue }
            let id = String(attrs[idRange])
            let href = String(attrs[hrefRange]).removingPercentEncoding ?? String(attrs[hrefRange])
            manifest[id] = href
        }
        return manifest
    }

    /// Parse spine: ordered list of item IDs
    private static func parseSpine(from opf: String) -> [String] {
        var ids: [String] = []
        let pattern = #"<itemref\s+[^>]*idref="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ids }
        let range = NSRange(opf.startIndex..<opf.endIndex, in: opf)
        for match in regex.matches(in: opf, range: range) {
            if let idRange = Range(match.range(at: 1), in: opf) {
                ids.append(String(opf[idRange]))
            }
        }
        return ids
    }

    // MARK: - TOC Parsing

    private struct TOCEntry {
        let title: String
        let href: String // relative to OPF dir, without fragment
        let navClass: String?
    }

    private static func preferredChapterTOCHrefs(_ entries: [TOCEntry]) -> Set<String>? {
        let chapterEntries = entries.filter { entry in
            guard let navClass = entry.navClass?.lowercased() else { return false }
            return navClass
                .split(whereSeparator: { $0.isWhitespace })
                .contains { $0 == "chapter" || $0.hasSuffix("-chapter") }
        }
        guard chapterEntries.count >= 2 else { return nil }
        return Set(chapterEntries.map { URL(fileURLWithPath: $0.href).lastPathComponent.lowercased() })
    }

    /// Try NCX first, then nav.xhtml
    private static func parseTOC(opfContent: String, manifest: [String: String], opfDir: String) -> [TOCEntry] {
        // Find NCX file from manifest
        if let ncxHref = manifest.values.first(where: { $0.lowercased().hasSuffix(".ncx") }),
           let ncxPath = safeResolvedPath(base: opfDir, href: ncxHref) {
            if let ncxContent = try? String(contentsOfFile: ncxPath, encoding: .utf8) {
                let entries = parseNCX(ncxContent)
                if !entries.isEmpty { return entries }
            }
        }

        // Find nav document (properties and href can appear in either order)
        let navPattern1 = #"<item\s+[^>]*properties="[^"]*nav[^"]*"[^>]*href="([^"]+)""#
        let navPattern2 = #"<item\s+[^>]*href="([^"]+)"[^>]*properties="[^"]*nav[^"]*""#
        let navHref: String? = [navPattern1, navPattern2].lazy.compactMap { pattern -> String? in
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: opfContent, range: NSRange(opfContent.startIndex..<opfContent.endIndex, in: opfContent)),
                  let range = Range(match.range(at: 1), in: opfContent) else { return nil }
            return String(opfContent[range]).removingPercentEncoding ?? String(opfContent[range])
        }.first
        if let navHref, let navPath = safeResolvedPath(base: opfDir, href: navHref) {
            if let navContent = try? String(contentsOfFile: navPath, encoding: .utf8) {
                let entries = parseNavXHTML(navContent)
                if !entries.isEmpty { return entries }
            }
        }

        return []
    }

    /// Parse NCX navMap: extract navPoint labels and content src
    private static func parseNCX(_ ncx: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        // Match each navPoint's text label and content src
        let pattern = #"<navPoint\b([^>]*)>.*?<text>([\s\S]*?)</text>.*?<content\s+src="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return entries
        }
        let range = NSRange(ncx.startIndex..<ncx.endIndex, in: ncx)
        for match in regex.matches(in: ncx, range: range) {
            if let attrsRange = Range(match.range(at: 1), in: ncx),
               let titleRange = Range(match.range(at: 2), in: ncx),
               let srcRange = Range(match.range(at: 3), in: ncx) {
                let attrs = String(ncx[attrsRange])
                let title = stripHTML(String(ncx[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                var src = String(ncx[srcRange]).removingPercentEncoding ?? String(ncx[srcRange])
                // Strip fragment
                if let hash = src.firstIndex(of: "#") { src = String(src[..<hash]) }
                if !title.isEmpty {
                    entries.append(TOCEntry(title: title, href: src, navClass: attribute("class", in: attrs)))
                }
            }
        }
        return entries
    }

    /// Parse EPUB3 nav.xhtml: extract <a> tags from the <nav epub:type="toc"> section
    private static func parseNavXHTML(_ nav: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        let tocHTML: String
        let navPattern = #"<nav\b(?=[^>]*(?:epub:type="[^"]*\btoc\b[^"]*"|role="doc-toc"))[^>]*>([\s\S]*?)</nav>"#
        if let navRegex = try? NSRegularExpression(pattern: navPattern, options: .caseInsensitive),
           let match = navRegex.firstMatch(in: nav, range: NSRange(nav.startIndex..<nav.endIndex, in: nav)),
           let bodyRange = Range(match.range(at: 1), in: nav) {
            tocHTML = String(nav[bodyRange])
        } else {
            tocHTML = nav
        }

        let pattern = #"<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return entries }
        let range = NSRange(tocHTML.startIndex..<tocHTML.endIndex, in: tocHTML)
        for match in regex.matches(in: tocHTML, range: range) {
            if let hrefRange = Range(match.range(at: 1), in: tocHTML),
               let titleRange = Range(match.range(at: 2), in: tocHTML) {
                var href = String(tocHTML[hrefRange]).removingPercentEncoding ?? String(tocHTML[hrefRange])
                if let hash = href.firstIndex(of: "#") { href = String(href[..<hash]) }
                let title = stripHTML(String(tocHTML[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    entries.append(TOCEntry(title: title, href: href, navClass: nil))
                }
            }
        }
        return entries
    }

    /// Some PDF-to-EPUB converters put every source-page spread in the TOC as
    /// `Page 12` or `Pages 12–13`. When the book also contains a real contents
    /// page, use that publisher-authored outline to recover semantic boundaries.
    /// Reading units without a matching heading remain part of the preceding
    /// chapter instead of becoming falsely named chapters of their own.
    private static func semanticTOCEntriesIfNeeded(
        _ entries: [TOCEntry],
        spineFiles: [(id: String, path: String)]
    ) -> [TOCEntry] {
        let genericCount = entries.count(where: { isGenericChapterLabel($0.title) })
        guard genericCount >= 2, genericCount * 2 >= entries.count else { return entries }

        let headingLists = spineFiles.map { extractHeadings(from: $0.path) }
        guard let contentsIndex = headingLists.firstIndex(where: { headings in
            guard headings.count >= 3, let first = headings.first else { return false }
            let key = semanticHeadingKey(first)
            return key == "contents" || key == "tableofcontents"
        }) else { return entries }

        let contentsHeadings = headingLists[contentsIndex]
        var exactTitles: [String: String] = [:]
        var descriptiveCandidates: [String: [String]] = [:]
        for heading in contentsHeadings {
            let title = normalizeChapterTitle(heading)
            exactTitles[semanticHeadingKey(title), default: title] = title
            descriptiveCandidates[semanticHeadingKey(title, stripsLeadingNumber: true), default: []].append(title)
        }
        let descriptiveTitles = descriptiveCandidates.compactMapValues { titles in
            Set(titles).count == 1 ? titles[0] : nil
        }

        var pathToSpineIndex: [String: Int] = [:]
        for (index, item) in spineFiles.enumerated() {
            pathToSpineIndex[URL(fileURLWithPath: item.path).lastPathComponent.lowercased()] = index
        }
        var resolved: [TOCEntry] = []
        for entry in entries {
            guard isGenericChapterLabel(entry.title) else {
                resolved.append(entry)
                continue
            }
            let filename = URL(fileURLWithPath: entry.href).lastPathComponent.lowercased()
            guard let spineIndex = pathToSpineIndex[filename] else { continue }
            let semanticTitle = headingLists[spineIndex].lazy.compactMap { heading -> String? in
                exactTitles[semanticHeadingKey(heading)]
                    ?? descriptiveTitles[semanticHeadingKey(heading, stripsLeadingNumber: true)]
            }.first
            if let semanticTitle {
                resolved.append(TOCEntry(title: semanticTitle, href: entry.href, navClass: entry.navClass))
            }
        }

        // Do not discard a usable TOC when the apparent contents page was noise.
        return resolved.count >= 2 ? resolved : entries
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b\#(escapedName)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)),
              let range = Range(match.range(at: 1), in: attrs) else { return nil }
        return String(attrs[range])
    }

    // MARK: - Chapter Building

    /// Group spine files by TOC entry boundaries
    private static func buildChaptersFromTOC(
        tocEntries: [TOCEntry],
        spineFiles: [(id: String, path: String)],
        opfDir: String,
        includedHrefs: Set<String>?
    ) -> [EPUBChapter] {
        // Build a map: normalized filename → spine index
        var fileToSpineIndex: [String: Int] = [:]
        for (idx, item) in spineFiles.enumerated() {
            let normalized = URL(fileURLWithPath: item.path).lastPathComponent.lowercased()
            fileToSpineIndex[normalized] = idx
        }

        // Match TOC entries to spine indices
        struct ChapterRange {
            let title: String
            let startIndex: Int
        }
        var ranges: [ChapterRange] = []
        for entry in tocEntries {
            let normalized = URL(fileURLWithPath: entry.href).lastPathComponent.lowercased()
            if let spineIdx = fileToSpineIndex[normalized] {
                // Avoid duplicates at same spine index
                if ranges.last?.startIndex == spineIdx { continue }
                ranges.append(ChapterRange(title: entry.title, startIndex: spineIdx))
            }
        }

        guard !ranges.isEmpty else {
            // Fall back to one file per chapter
            return spineFiles.enumerated().compactMap { idx, item in
                guard let result = extractTextAndHTML(from: item.path) else { return nil }
                return EPUBChapter(title: normalizeChapterTitle(titleFromFilename(item.path)), textContent: result.text, htmlContent: result.html, order: idx)
            }
        }

        // Build chapters from ranges
        var chapters: [EPUBChapter] = []
        for (i, chRange) in ranges.enumerated() {
            let endIndex = (i + 1 < ranges.count) ? ranges[i + 1].startIndex - 1 : spineFiles.count - 1
            guard chRange.startIndex <= endIndex else { continue }
            let chapterHref = URL(fileURLWithPath: spineFiles[chRange.startIndex].path).lastPathComponent.lowercased()
            if let includedHrefs, !includedHrefs.contains(chapterHref) { continue }

            var combinedText = ""
            var combinedHTML = ""
            for fileIdx in chRange.startIndex...endIndex {
                guard fileIdx < spineFiles.count else { break }
                if let result = extractTextAndHTML(from: spineFiles[fileIdx].path) {
                    if !combinedText.isEmpty { combinedText += "\n\n" }
                    if !combinedHTML.isEmpty { combinedHTML += "\n" }
                    combinedText += result.text
                    combinedHTML += result.html
                }
            }
            if !combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let title = bestChapterTitle(tocTitle: chRange.title, xhtmlPath: spineFiles[chRange.startIndex].path)
                chapters.append(EPUBChapter(title: title, textContent: combinedText, htmlContent: combinedHTML, order: i))
            }
        }

        return chapters
    }

    // MARK: - Chapter Title Improvement

    /// Extract the first <h1> or <h2> heading from an HTML file as a title.
    private static func extractHeading(from htmlPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: htmlPath),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return extractHeadingFromHTML(html)
    }

    /// Extract the first <h1> or <h2> heading from HTML content.
    static func extractHeadingFromHTML(_ html: String) -> String? {
        extractHeadingsFromHTML(html).first
    }

    private static func extractHeadings(from htmlPath: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: htmlPath),
              let html = String(data: data, encoding: .utf8) else { return [] }
        return extractHeadingsFromHTML(html)
    }

    private static func extractHeadingsFromHTML(_ html: String) -> [String] {
        let pattern = #"<h[1-2]\b[^>]*>([\s\S]*?)</h[1-2]>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match -> String? in
            guard let contentRange = Range(match.range(at: 1), in: html) else { return nil }
            let raw = String(html[contentRange])
            let stripped = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty || stripped.count <= 1 ? nil : stripped
        }
    }

    /// Returns true if a title looks like an internal filename rather than a real chapter title.
    /// E.g. "Ch0 Fm1 Endorsement", "ch03_section2", "OEBPS-003"
    private static func looksLikeInternalName(_ title: String) -> Bool {
        return false
    }

    /// Normalize common EPUB chapter labels to the same display shape used for
    /// split PDF books: "Chapter 1 ◾ Title" -> "1) Title".
    static func normalizeChapterTitle(_ title: String) -> String {
        title.decodingHTMLCharacterReferences()
            .removingSoftHyphens()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bestChapterTitle(tocTitle: String, xhtmlPath: String) -> String {
        let normalizedTOC = normalizeChapterTitle(tocTitle)
        if !isGenericChapterLabel(normalizedTOC) { return normalizedTOC }
        return normalizeChapterTitle(extractHeading(from: xhtmlPath) ?? normalizedTOC)
    }

    static func isGenericChapterLabel(_ title: String) -> Bool {
        let normalized = normalizeChapterTitle(title)
        return normalized.range(
            of: #"^pages?\s+\d+(?:\s*[-–—]\s*\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func semanticHeadingKey(_ title: String, stripsLeadingNumber: Bool = false) -> String {
        var value = normalizeChapterTitle(title)
        if stripsLeadingNumber {
            value = value.replacingOccurrences(
                of: #"^\s*\d+(?:\.\d+)*\.?\s*"#,
                with: "",
                options: .regularExpression
            )
        }
        // Normalize the small set of Cyrillic lookalikes commonly introduced
        // by OCR in otherwise-Latin scientific headings (for example `АІН` for AIH).
        value = value
            .replacingOccurrences(of: "А", with: "A")
            .replacingOccurrences(of: "а", with: "a")
            .replacingOccurrences(of: "І", with: "I")
            .replacingOccurrences(of: "і", with: "i")
            .replacingOccurrences(of: "Н", with: "H")
            .replacingOccurrences(of: "н", with: "h")
        return value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func chapterNumberAndTitle(from title: String) -> (number: String, title: String)? {
        nil
    }

    private static func extractClassBasedHeadingFromHTML(_ html: String) -> String? {
        return nil
    }

    private static func uppercaseFirstCharacter(_ value: String) -> String {
        guard let first = value.first, first.isLowercase else { return value }
        return first.uppercased() + value.dropFirst()
    }

    /// Replace internal-looking titles with headings extracted from the chapter text.
    private static func improveChapterTitles(chapters: [EPUBChapter]) -> [EPUBChapter] {
        chapters
    }

    // MARK: - HTML Text Extraction

    /// Strip HTML tags and extract plain text from an HTML/XHTML file.
    private static func extractText(from htmlPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: htmlPath),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return stripHTML(html)
    }

    /// Extract both plain text and cleaned HTML body from an HTML/XHTML file.
    private static func extractTextAndHTML(from htmlPath: String) -> (text: String, html: String)? {
        guard let data = FileManager.default.contents(atPath: htmlPath),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return (text: stripHTML(html), html: extractBodyHTML(html))
    }

    /// Extract the <body> content from an HTML document, removing scripts/styles
    /// but preserving formatting tags (p, h1-h6, em, strong, blockquote, lists, etc.).
    static func extractBodyHTML(_ html: String) -> String {
        extractBodyHTML(html, removesMedia: true)
    }

    static func extractBodyHTML(_ html: String, removesMedia: Bool) -> String {
        var body = html
        // Try to extract just the <body> content
        if let bodyRegex = try? NSRegularExpression(pattern: #"<body[^>]*>([\s\S]*)</body>"#, options: .caseInsensitive),
           let match = bodyRegex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
           let bodyRange = Range(match.range(at: 1), in: html) {
            body = String(html[bodyRange])
        }
        // Remove script and style blocks
        if let regex = try? NSRegularExpression(pattern: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, options: .caseInsensitive) {
            body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body), withTemplate: "")
        }
        if removesMedia {
            // Remove image tags when returning standalone body snippets from a temp unzip.
            if let regex = try? NSRegularExpression(pattern: #"<img[^>]*/?>"#, options: .caseInsensitive) {
                body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body), withTemplate: "")
            }
            // Remove SVG blocks
            if let regex = try? NSRegularExpression(pattern: #"<svg[\s\S]*?</svg>"#, options: .caseInsensitive) {
                body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body), withTemplate: "")
            }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip HTML tags, keeping meaningful whitespace.
    static func stripHTML(_ html: String) -> String {
        var text = html
        // Remove script/style blocks
        if let regex = try? NSRegularExpression(pattern: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "")
        }
        // Replace block elements with newlines
        if let regex = try? NSRegularExpression(pattern: #"</(p|div|h[1-6]|li|tr|br\s*/?)>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "\n")
        }
        // Also handle self-closing <br/> and <br />
        if let regex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "\n")
        }
        // Strip remaining tags
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "")
        }
        // Decode HTML character references. This text is reflowed for reading
        // and for AI context, so a no-break space — however it was written —
        // becomes a plain space, and a soft hyphen, the book's hint for where
        // a word may break, is dropped.
        text = text.decodingHTMLCharacterReferences()
            .removingSoftHyphens()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        // Collapse whitespace
        if let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize malformed embedded image data URIs seen in some EPUB exports.
    /// WebKit expects media types like `image/jpeg`; inputs like `image/.jpg`
    /// contain valid base64 image data but can fail to render.
    static func normalizeImageDataURIs(in html: String) -> String {
        var result = html
        let replacements = [
            (#"data:image/\.(?:jpg|jpeg);base64,"#, "data:image/jpeg;base64,"),
            (#"data:image/jpg;base64,"#, "data:image/jpeg;base64,"),
            (#"data:image/\.png;base64,"#, "data:image/png;base64,"),
            (#"data:image/\.gif;base64,"#, "data:image/gif;base64,"),
            (#"data:image/\.webp;base64,"#, "data:image/webp;base64,"),
            (#"data:image/\.svg\+xml;base64,"#, "data:image/svg+xml;base64,")
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: replacement
            )
        }
        return result
    }

    // MARK: - Helpers

    /// Join an untrusted EPUB href (from the OPF manifest or NCX/nav navigation)
    /// with a base directory inside the temp extraction dir, returning the resolved
    /// absolute path ONLY when it stays inside `base`. A malicious EPUB can contain
    /// hrefs like `../../../../etc/passwd`; such entries are skipped (returns nil) so
    /// the parser never reads files outside the extraction directory (path traversal).
    private static func safeResolvedPath(base: String, href: String) -> String? {
        let joined = (base as NSString).appendingPathComponent(href)
        let standardized = URL(fileURLWithPath: joined).standardizedFileURL.path
        let baseStandardized = URL(fileURLWithPath: base).standardizedFileURL.path
        if standardized == baseStandardized { return standardized }
        let prefix = baseStandardized.hasSuffix("/") ? baseStandardized : baseStandardized + "/"
        guard standardized.hasPrefix(prefix) else {
            logger.warning("[EPUBParser] Skipping EPUB entry that escapes the extraction directory: \(href, privacy: .public)")
            return nil
        }
        return standardized
    }

    private static func normalizeExtractedHTMLImageDataURIs(in directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "html" || ext == "htm" || ext == "xhtml" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let normalized = normalizeImageDataURIs(in: raw)
            guard normalized != raw else { continue }
            try? normalized.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func titleFromFilename(_ path: String) -> String {
        let name = (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension
        // Replace underscores/hyphens with spaces, capitalize
        return name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .localizedCapitalized
    }

    static func resolveImageReference(_ reference: String, relativeTo chapterPath: String) -> String? {
        var ref = reference.decodingHTMLCharacterReferences()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }

        let originalRef = ref
        let lower = ref.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
            return nil
        }

        if let hash = ref.firstIndex(of: "#") {
            ref = String(ref[..<hash])
        }
        if let query = ref.firstIndex(of: "?") {
            ref = String(ref[..<query])
        }
        ref = ref.removingPercentEncoding ?? ref

        let path: String
        if lower.hasPrefix("file://"), let url = URL(string: originalRef), url.isFileURL {
            path = url.path
        } else if ref.hasPrefix("/") {
            path = ref
        } else {
            let chapterDir = (chapterPath as NSString).deletingLastPathComponent
            path = (chapterDir as NSString).appendingPathComponent(ref)
        }

        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard isSupportedImagePath(standardized),
              FileManager.default.fileExists(atPath: standardized) else { return nil }
        return standardized
    }

    private static func isSupportedImagePath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp", "webp", "svg":
            return true
        default:
            return false
        }
    }

    static func rebaseLocalResourceReferences(in html: String, from sourcePath: String, toDirectory targetDir: String) -> String {
        let pattern = #"\b(src|href|xlink:href)\s*=\s*(["'])([^"']+)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return html }

        var rebased = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: rebased),
                  let nameRange = Range(match.range(at: 1), in: rebased),
                  let quoteRange = Range(match.range(at: 2), in: rebased),
                  let valueRange = Range(match.range(at: 3), in: rebased) else { continue }

            let attributeName = String(rebased[nameRange])
            let quote = String(rebased[quoteRange])
            let value = String(rebased[valueRange])
            guard let newValue = rebasedLocalReference(value, from: sourcePath, toDirectory: targetDir) else { continue }
            rebased.replaceSubrange(fullRange, with: "\(attributeName)=\(quote)\(escapeHTMLAttribute(newValue))\(quote)")
        }
        return rebased
    }

    static func rebasedLocalReference(_ reference: String, from sourcePath: String, toDirectory targetDir: String) -> String? {
        let decoded = reference.decodingHTMLCharacterReferences().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }

        let lower = decoded.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
            || lower.hasPrefix("data:") || lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:")
            || decoded.hasPrefix("#") {
            return nil
        }

        var pathPart = decoded
        var suffix = ""
        if let hash = pathPart.firstIndex(of: "#") {
            suffix = String(pathPart[hash...])
            pathPart = String(pathPart[..<hash])
        }
        if let query = pathPart.firstIndex(of: "?") {
            suffix = String(pathPart[query...]) + suffix
            pathPart = String(pathPart[..<query])
        }
        guard !pathPart.isEmpty else { return nil }

        let sourceDir = (sourcePath as NSString).deletingLastPathComponent
        let absolutePath: String
        if lower.hasPrefix("file://"), let url = URL(string: decoded), url.isFileURL {
            absolutePath = url.path
        } else if pathPart.hasPrefix("/") {
            absolutePath = pathPart
        } else {
            absolutePath = (sourceDir as NSString).appendingPathComponent(pathPart.removingPercentEncoding ?? pathPart)
        }

        let standardized = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let relative = relativePath(from: targetDir, to: standardized)
        return relative + suffix
    }

    private static func relativePath(from baseDir: String, to targetPath: String) -> String {
        let baseComponents = URL(fileURLWithPath: baseDir, isDirectory: true).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: targetPath).standardizedFileURL.pathComponents
        var sharedCount = 0
        while sharedCount < baseComponents.count,
              sharedCount < targetComponents.count,
              baseComponents[sharedCount] == targetComponents[sharedCount] {
            sharedCount += 1
        }

        let up = Array(repeating: "..", count: max(0, baseComponents.count - sharedCount))
        let down = Array(targetComponents.dropFirst(sharedCount))
        let components = up + down
        return components.isEmpty ? URL(fileURLWithPath: targetPath).lastPathComponent : components.joined(separator: "/")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func extractXMLElement(_ element: String, from xml: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: element))[^>]*>([^<]+)</\(NSRegularExpression.escapedPattern(for: element))>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
              let contentRange = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[contentRange])
    }

    private static func extractMetaContent(property: String, from xml: String) -> String? {
        extractMetaContent(attribute: "property", value: property, from: xml)
    }

    private static func extractMetaContent(name: String, from xml: String) -> String? {
        extractMetaContent(attribute: "name", value: name, from: xml)
    }

    /// The `content` of the first `<meta>` whose `attribute` is `value`, read
    /// inside its own tag in either attribute order (`HTMLTagAttributes`);
    /// then, for EPUB 3's `<meta property="…">text</meta>`, the element's text.
    private static func extractMetaContent(
        attribute: String,
        value: String,
        from xml: String,
        allowsElementText: Bool = true
    ) -> String? {
        let content = HTMLTagAttributes.tags(named: "meta", in: xml).lazy
            .filter { $0[attribute]?.caseInsensitiveCompare(value) == .orderedSame }
            .compactMap { $0["content"] }
            .first { !$0.isEmpty }
        if let content { return content }
        guard allowsElementText else { return nil }

        let escapedAttribute = NSRegularExpression.escapedPattern(for: attribute)
        let escapedValue = NSRegularExpression.escapedPattern(for: value)
        let elementContentPattern = #"<meta\b(?=[^>]*\b\#(escapedAttribute)\s*=\s*["']\#(escapedValue)["'])[^>]*>([^<]+)</meta>"#
        return firstRegexCapture(elementContentPattern, in: xml)
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Illustrated reader documents

    /// A book chapter prepared for a device that does not have the book files.
    ///
    /// The phone only ever receives a source's *text*, and `stripHTML` deletes
    /// `<img>` and `<svg>` outright, so an illustrated chapter used to arrive on
    /// iOS with every figure silently missing. This rebuilds the chapter as one
    /// self-contained string — the chapter's own markup with each local image
    /// inlined as a `data:` URI — which renders with a nil base URL and cannot
    /// reach the network.
    struct ReaderDocument: Sendable, Equatable {
        /// Sanitized body HTML: no script, no stylesheet link, and no reference
        /// that leaves the document.
        let html: String
        /// Images inlined as `data:` URIs.
        let inlinedImageCount: Int
        /// Images replaced by a visible note — unreadable, or past the byte
        /// budget. Silently dropping one would look like the book never had it.
        let omittedImageCount: Int
    }

    /// Longest side an inlined raster image keeps. A phone reader never shows
    /// more than ~1200pt across at 3x, and print-resolution plates are common in
    /// EPUBs.
    private static let maxReaderImagePixelSize = 1600
    /// Images at or below this stay byte-identical: re-encoding a small figure
    /// costs quality and saves nothing.
    private static let maxReaderVerbatimImageBytes = 256 * 1024
    /// Bound for the two kinds that must travel byte-for-byte: SVG, which is
    /// markup and stays sharp at any zoom, and GIF, which ImageIO would flatten
    /// to a single frame.
    private static let maxReaderVerbatimOnlyImageBytes = 1024 * 1024
    /// Whole-document ceiling, well under CloudKit's asset limit and the 30 MB
    /// Mac -> iOS convention `makeSourcePDFAsset` uses. A photographic chapter
    /// stops adding images here rather than making the record unsyncable.
    static let maxReaderDocumentBytes = 12 * 1024 * 1024

    /// True for the chapter shapes that carry markup — an EPUB import writes
    /// `.xhtml`, older imports `.html`. PDF-backed chapters sync their PDF
    /// instead and never come through here.
    static func isMarkupChapter(_ path: String) -> Bool {
        ["html", "htm", "xhtml"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Builds the reader document for a local markup file, resolving images
    /// beside it. Used by extracted EPUB chapters and archived web articles.
    ///
    /// File and ImageIO work: callers must stay off the main actor.
    static func readerDocument(
        forMarkupAt path: String,
        maximumBytes: Int = EPUBParser.maxReaderDocumentBytes
    ) -> ReaderDocument? {
        guard isMarkupChapter(path), let html = readChapterMarkup(at: path) else { return nil }
        return readerDocument(fromHTML: html, chapterPath: path, maximumBytes: maximumBytes)
    }

    static func readerDocument(
        forChapterAt path: String,
        maximumBytes: Int = EPUBParser.maxReaderDocumentBytes
    ) -> ReaderDocument? {
        readerDocument(forMarkupAt: path, maximumBytes: maximumBytes)
    }

    /// Testable core: the same transformation with the markup already in hand.
    /// `chapterPath` still resolves image references, exactly as the Mac reader's
    /// base URL does.
    static func readerDocument(
        fromHTML html: String,
        chapterPath: String,
        maximumBytes: Int = EPUBParser.maxReaderDocumentBytes
    ) -> ReaderDocument {
        let body = removingUnsafeMarkup(
            in: extractBodyHTML(normalizeImageDataURIs(in: html), removesMedia: false)
        )
        var remaining = max(0, maximumBytes - body.utf8.count)
        var inlined = 0
        var omitted = 0
        let inlinedBody = inliningMediaReferences(
            in: body,
            chapterPath: chapterPath,
            remainingBytes: &remaining,
            inlinedCount: &inlined,
            omittedCount: &omitted
        )
        return ReaderDocument(
            html: inlinedBody,
            inlinedImageCount: inlined,
            omittedImageCount: omitted
        )
    }

    /// EPUB chapters are usually UTF-8; a few older exports are Latin-1, and
    /// reading those as UTF-8 fails outright rather than mojibake.
    private static func readChapterMarkup(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Everything a chapter must not carry onto another device. `extractBodyHTML`
    /// has already removed `<script>` and `<style>` blocks; this removes what is
    /// left that can execute, load, or navigate — publisher inline styles stay,
    /// because the reader stylesheet overrides the ones that matter.
    private static func removingUnsafeMarkup(in html: String) -> String {
        var body = html
        let removals = [
            #"<(iframe|object|embed|form|noscript)\b[\s\S]*?</\1>"#,
            #"<(link|meta|base|input|button|source|track)\b[^>]*/?>"#,
            #"\s(on[a-z]+)\s*=\s*("[^"]*"|'[^']*')"#,
            #"\s(srcset|data-srcset)\s*=\s*("[^"]*"|'[^']*')"#,
        ]
        for pattern in removals {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            body = regex.stringByReplacingMatches(
                in: body,
                range: NSRange(body.startIndex..<body.endIndex, in: body),
                withTemplate: ""
            )
        }
        // A javascript: URL cannot run in the reader (taps never navigate), but
        // it has no business travelling with the chapter either.
        if let regex = try? NSRegularExpression(
            pattern: #"(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2"#,
            options: .caseInsensitive
        ) {
            body = regex.stringByReplacingMatches(
                in: body,
                range: NSRange(body.startIndex..<body.endIndex, in: body),
                withTemplate: ""
            )
        }
        return body
    }

    /// Rewrites every `<img>`/`<image>` reference to an inlined `data:` URI.
    /// Tags are processed last-first so earlier replacements cannot invalidate
    /// later ranges.
    private static func inliningMediaReferences(
        in html: String,
        chapterPath: String,
        remainingBytes: inout Int,
        inlinedCount: inout Int,
        omittedCount: inout Int
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(img|image)\b[^>]*?/?>"#,
            options: .caseInsensitive
        ) else {
            return html
        }

        var rewritten = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
        // Count forward so a budget exhausted mid-document omits the *later*
        // images, matching reading order, then apply the edits in reverse.
        var replacements: [(range: Range<String.Index>, markup: String)] = []
        for match in matches {
            guard let range = Range(match.range(at: 0), in: rewritten) else { continue }
            let tag = String(rewritten[range])
            let referenceAttributes = ["src", "data-src", "xlink:href", "href"]
            guard let attribute = referenceAttributes.first(where: { attributeValue($0, in: tag) != nil }),
                  let reference = attributeValue(attribute, in: tag) else {
                // A tag with no reference at all: nothing to inline, nothing lost.
                continue
            }

            if reference.lowercased().hasPrefix("data:") {
                inlinedCount += 1
                continue
            }
            guard let imagePath = resolveImageReference(reference, relativeTo: chapterPath),
                  let dataURI = imageDataURI(atPath: imagePath) else {
                omittedCount += 1
                replacements.append((range, omittedImageMarkup))
                continue
            }
            let cost = dataURI.utf8.count
            guard cost <= remainingBytes else {
                omittedCount += 1
                replacements.append((range, omittedImageMarkup))
                continue
            }
            remainingBytes -= cost
            inlinedCount += 1
            replacements.append((range, settingAttribute(attribute, to: dataURI, in: tag)))
        }

        for replacement in replacements.reversed() {
            rewritten.replaceSubrange(replacement.range, with: replacement.markup)
        }
        return rewritten
    }

    /// Inline so it can sit inside a paragraph without splitting it. The reader
    /// stylesheet styles this class as a muted note.
    private static let omittedImageMarkup =
        "<span class=\"flm-image-omitted\">Image not synced — open this book on your Mac.</span>"

    /// One image as a `data:` URI, re-encoded only when it has to be. nil for a
    /// file ImageIO cannot read, which the caller turns into a visible note.
    static func imageDataURI(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let fileExtension = url.pathExtension.lowercased()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil,
              size > 0 else {
            return nil
        }

        // SVG is markup: inlining the bytes keeps it sharp at any zoom.
        if fileExtension == "svg" {
            guard size <= maxReaderVerbatimOnlyImageBytes, let data = try? Data(contentsOf: url) else { return nil }
            return dataURI(mediaType: "image/svg+xml", data: data)
        }
        // Re-encoding a GIF through ImageIO keeps one frame and loses the
        // animation, so an animated figure is inlined verbatim or not at all.
        if fileExtension == "gif" {
            guard size <= maxReaderVerbatimOnlyImageBytes, let data = try? Data(contentsOf: url) else { return nil }
            return dataURI(mediaType: "image/gif", data: data)
        }
        if size <= maxReaderVerbatimImageBytes,
           let mediaType = webSafeImageMediaType(forExtension: fileExtension),
           let data = try? Data(contentsOf: url) {
            return dataURI(mediaType: mediaType, data: data)
        }
        guard let downscaled = downscaledImage(at: url) else {
            // TIFF/BMP that ImageIO refused has no web-safe verbatim form.
            guard let mediaType = webSafeImageMediaType(forExtension: fileExtension),
                  let data = try? Data(contentsOf: url) else { return nil }
            return dataURI(mediaType: mediaType, data: data)
        }
        return dataURI(mediaType: downscaled.mediaType, data: downscaled.data)
    }

    private static func webSafeImageMediaType(forExtension fileExtension: String) -> String? {
        switch fileExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }

    /// Downscales with ImageIO. Alpha decides the output format: a transparent
    /// line drawing encoded as JPEG comes back with a black background, which is
    /// worse than the extra PNG bytes.
    private static func downscaledImage(at url: URL) -> (data: Data, mediaType: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxReaderImagePixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let type: UTType = hasAlpha ? .png : .jpeg
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let encodingOptions: CFDictionary? = hasAlpha
            ? nil
            : [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, encodingOptions)
        guard CGImageDestinationFinalize(destination), !(encoded as Data).isEmpty else { return nil }
        return (data: encoded as Data, mediaType: hasAlpha ? "image/png" : "image/jpeg")
    }

    private static func dataURI(mediaType: String, data: Data) -> String {
        "data:\(mediaType);base64,\(data.base64EncodedString())"
    }

    /// Reads one attribute out of a single tag. The lookbehind keeps a search for
    /// `href` from matching the `href` inside `xlink:href`.
    static func attributeValue(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?<![\w:.-])\#(escaped)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: tag) else { continue }
            return String(tag[range])
        }
        return nil
    }

    private static func settingAttribute(_ name: String, to value: String, in tag: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?<![\w:.-])\#(escaped)\s*=\s*(?:"[^"]*"|'[^']*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let range = Range(match.range(at: 0), in: tag) else {
            return tag
        }
        var updated = tag
        updated.replaceSubrange(range, with: "\(name)=\"\(escapeHTMLAttribute(value))\"")
        return updated
    }
}
